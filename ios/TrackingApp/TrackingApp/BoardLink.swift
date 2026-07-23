import Foundation
import CoreBluetooth
import SensorCore

/// Which tag this link talks to. Raw values are the advertised names set by
/// the firmware (`sensor_ble.c`).
public enum BoardRole: String, CaseIterable {
    case initiator = "DWM-INIT"
    case responder = "DWM-RESP"
}

/// Human-facing connection state for one board's link. A typed enum, not a
/// bare String, so BoardModel's epoch logic and the view can't silently drift
/// from the states BoardLink actually emits — renaming a case is a compile
/// error, not a stat that quietly stops resetting.
public enum LinkState: Equatable {
    case starting
    case searching
    case connecting
    case connected
    case streaming
    case bluetoothOff
    case permissionDenied
    case unavailable

    /// Lower-case label shown in the live view.
    public var label: String {
        switch self {
        case .starting:         return "starting"
        case .searching:        return "searching"
        case .connecting:       return "connecting"
        case .connected:        return "connected"
        case .streaming:        return "streaming"
        case .bluetoothOff:     return "bluetooth off"
        case .permissionDenied: return "permission denied"
        case .unavailable:      return "unavailable"
        }
    }
}

/// Talks to one tag over BLE and forwards decoded packets upward.
///
/// Deliberately does no arithmetic: rate and loss are computed by `LinkStats`
/// in `SensorCore`, which is testable without a radio. This class only owns
/// the parts that genuinely require hardware.
final class BoardLink: NSObject {

    static let serviceUUID = CBUUID(string: "6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E")
    static let sensorUUID  = CBUUID(string: "6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E")

    let role: BoardRole

    private let countLock = NSLock()
    private var _disconnectCount = 0

    /// Safe to read from any thread; written on the BLE queue.
    var disconnectCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return _disconnectCount
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let onPacket: (SensorPacket, TimeInterval) -> Void
    private let onState: (LinkState) -> Void

    init(role: BoardRole,
         onPacket: @escaping (SensorPacket, TimeInterval) -> Void,
         onState: @escaping (LinkState) -> Void) {
        self.role = role
        self.onPacket = onPacket
        self.onState = onState
        super.init()
    }

    func start() {
        // A dedicated queue keeps 100 Hz of delegate callbacks off the main
        // thread, so the UI can never become the bottleneck we're measuring.
        central = CBCentralManager(delegate: self,
                                   queue: DispatchQueue(label: "ble.\(role.rawValue)"))
    }

    private func scan() {
        // Scanning is only legal once the central is powered on; calling it in
        // any other state is an API-misuse no-op. The callers (disconnect,
        // connect-failure, power-on) don't all know the current state, so gate
        // it here rather than at each call site.
        guard central.state == .poweredOn else { return }
        onState(.searching)
        // The firmware puts the service UUID in the SCAN RESPONSE, not the
        // primary advertisement. iOS usually merges the two, but that's a
        // known grey area — if it doesn't, filtering on `serviceUUID` here
        // finds nothing at all. The board name (in the primary advertisement)
        // is the real discriminator and is what `didDiscover` actually
        // checks below, so scan unfiltered and let that guard do the work.
        // Background scanning would require a non-nil service list, but
        // background operation is out of scope for this milestone.
        central.scanForPeripherals(withServices: nil)
    }
}

extension BoardLink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Redelivered .poweredOn while connected must not start a second scan.
            if peripheral == nil { scan() }
        case .poweredOff:
            // The connection is gone, but iOS does not reliably deliver
            // didDisconnect for a power-off — so drop the stale peripheral
            // here. Otherwise the `peripheral == nil` guard above would
            // suppress the re-scan when Bluetooth comes back, and the link
            // would never recover until the app is relaunched.
            peripheral = nil
            onState(.bluetoothOff)
        case .unauthorized:
            onState(.permissionDenied)
        default:
            peripheral = nil
            onState(.unavailable)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Match on the advertised name, which the firmware sets per role.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        guard name == role.rawValue else { return }

        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        onState(.connecting)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onState(.connected)
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        countLock.lock()
        _disconnectCount += 1
        countLock.unlock()
        self.peripheral = nil
        scan()                                  // auto-reconnect
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil                   // parity with didDisconnect
        scan()
    }
}

extension BoardLink: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics([Self.sensorUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.sensorUUID })
        else { return }
        peripheral.setNotifyValue(true, for: ch)
        onState(.streaming)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Timestamp first: this is as close to arrival as we can observe.
        // Uses the monotonic clock, not wall time: an NTP sync or user clock
        // change can step Date() backwards, which would violate LinkStats.
        // record's non-decreasing-time precondition and silently skew rate.
        let now = ProcessInfo.processInfo.systemUptime
        guard let data = characteristic.value,
              let packet = SensorPacket(data) else { return }
        onPacket(packet, now)
    }
}
