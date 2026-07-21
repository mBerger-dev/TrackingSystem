import Foundation
import CoreBluetooth
import SensorCore

/// Which tag this link talks to. Raw values are the advertised names set by
/// the firmware (`sensor_ble.c`).
public enum BoardRole: String, CaseIterable {
    case initiator = "DWM-INIT"
    case responder = "DWM-RESP"
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
    private let onState: (String) -> Void

    init(role: BoardRole,
         onPacket: @escaping (SensorPacket, TimeInterval) -> Void,
         onState: @escaping (String) -> Void) {
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
        onState("searching")
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }
}

extension BoardLink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Redelivered .poweredOn while connected must not start a second scan.
            if peripheral == nil { scan() }
        case .poweredOff: onState("bluetooth off")
        case .unauthorized: onState("permission denied")
        default: onState("unavailable")
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
        onState("connecting")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onState("connected")
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
        onState("streaming")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Timestamp first: this is as close to arrival as we can observe.
        let now = Date().timeIntervalSince1970
        guard let data = characteristic.value,
              let packet = SensorPacket(data) else { return }
        onPacket(packet, now)
    }
}
