# M3a — iOS Live View + Link Measurement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone app connects to both tags, shows per-board live values, and measures what fraction of the 100 Hz stream actually arrives.

**Architecture:** The measurement itself (`LinkStats`) is pure Swift in the existing `SensorCore` package, tested on macOS with no hardware. CoreBluetooth lives in the app target as a thin adapter that forwards raw bytes plus an arrival timestamp. Packets update plain state at ~200/sec; a 10 Hz timer publishes snapshots to SwiftUI so the render rate never chases the radio rate.

**Tech Stack:** Swift 5.9+, SwiftPM (`SensorCore`), SwiftUI + `@Observable`, CoreBluetooth, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-21-m3a-ios-live-view-design.md`

## Global Constraints

- **Wire contract is frozen** — `firmware/ble-contract.md`. 16 bytes little-endian: `seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32`. No firmware changes in this milestone.
- **Service UUID:** `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
- **Notify characteristic UUID:** `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
- **Board names:** `DWM-INIT` (reports real `uwb_mm`) and `DWM-RESP` (always sentinel).
- **`SensorCore` must not import CoreBluetooth.** Its tests run via `swift test` on macOS with no device attached. This is what makes the measurement verifiable.
- **`seq` is `UInt16` and wraps every 65536 packets** (~11 min at 100 Hz). A wrap is not loss.
- **No pass bar.** M3a records the measured rate and loss; it does not act on them.
- **Device-only:** CoreBluetooth does nothing in the Simulator. Every UI/link check needs the phone.
- **Free provisioning:** builds expire after 7 days; re-deploy from Xcode before a session.

---

### Task 1: `LinkStats` — the measurement

The whole milestone reduces to this type being correct. It takes `(seq, arrivalTime)` pairs and reports rate and loss. It knows nothing about Bluetooth.

**Files:**
- Create: `ios/SensorCore/Sources/SensorCore/LinkStats.swift`
- Test: `ios/SensorCore/Tests/SensorCoreTests/LinkStatsTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `LinkStats.init(rateWindow: TimeInterval = 2.0)`
  - `mutating func record(seq: UInt16, at time: TimeInterval)`
  - `var snapshot: LinkStats.Snapshot`
  - `LinkStats.Snapshot` with `received: Int`, `expected: Int`, `lost: Int`, `lossFraction: Double`, `packetsPerSecond: Double`, `epochs: Int`

**Counting rules** (implement exactly; the tests below encode them):

Let `fwd = Int(seq &- lastSeq)` — unsigned wrapping subtraction, so it is always `0...65535`.

| Condition | Meaning | Action |
|---|---|---|
| first packet ever | start | `received=1, expected=1, epochs=1, lastSeq=seq` |
| `fwd == 0` | duplicate | `received += 1` only |
| `1 <= fwd <= 32768` | normal forward step (a wrap 65535→0 gives `fwd == 1`) | `expected += fwd; received += 1; lastSeq = seq` |
| `fwd > 32768` and `65536-fwd <= 64` | out-of-order arrival | `received += 1` only |
| `fwd > 32768` and `65536-fwd > 64` | board rebooted | new epoch: `epochs += 1; received = 1; expected = 1; lastSeq = seq`, clear rate window |

`lost = max(0, expected - received)`, `lossFraction = expected > 0 ? Double(lost)/Double(expected) : 0`.

Rate uses a sliding window of arrival times: drop entries older than `rateWindow`, then `packetsPerSecond = (count - 1) / (newest - oldest)`, or `0` when fewer than 2 remain.

- [ ] **Step 1: Write the failing tests**

Create `ios/SensorCore/Tests/SensorCoreTests/LinkStatsTests.swift`:

```swift
import XCTest
@testable import SensorCore

final class LinkStatsTests: XCTestCase {

    /// Feed a clean run of sequence numbers, one every 10 ms.
    private func feed(_ seqs: [UInt16], into stats: inout LinkStats, startAt t0: TimeInterval = 0) {
        for (i, s) in seqs.enumerated() {
            stats.record(seq: s, at: t0 + Double(i) * 0.01)
        }
    }

    func testCleanRunHasNoLoss() {
        var stats = LinkStats()
        feed([1, 2, 3, 4, 5], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.received, 5)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 0)
        XCTAssertEqual(s.lossFraction, 0.0, accuracy: 1e-9)
    }

    func testSingleGapCountsOneLost() {
        var stats = LinkStats()
        feed([1, 2, 4, 5], into: &stats)   // 3 never arrived
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 1)
        XCTAssertEqual(s.lossFraction, 0.2, accuracy: 1e-9)
    }

    func testSeveralGapsSumCorrectly() {
        var stats = LinkStats()
        feed([1, 3, 4, 9], into: &stats)   // lost 2, then 5,6,7,8 -> 5 total
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 9)
        XCTAssertEqual(s.lost, 5)
    }

    func testWrapAtUInt16BoundaryIsNotLoss() {
        var stats = LinkStats()
        feed([65534, 65535, 0, 1], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 4)
        XCTAssertEqual(s.lost, 0, "65535 -> 0 is a step of one, not 65k lost packets")
        XCTAssertEqual(s.epochs, 1, "a wrap must not look like a reboot")
    }

    func testOutOfOrderArrivalIsNotCountedAsReboot() {
        var stats = LinkStats()
        feed([1, 2, 4, 3, 5], into: &stats)   // 3 arrives late
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 1)
        XCTAssertEqual(s.received, 5)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 0, "the late packet fills the gap it left")
    }

    func testDuplicateDoesNotAdvanceExpected() {
        var stats = LinkStats()
        feed([1, 2, 2, 3], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.expected, 3)
        XCTAssertEqual(s.received, 4)
    }

    func testBoardResetStartsNewEpoch() {
        var stats = LinkStats()
        feed([5000, 5001, 5002], into: &stats)
        stats.record(seq: 0, at: 0.10)        // board rebooted, seq restarts
        stats.record(seq: 1, at: 0.11)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 2)
        XCTAssertEqual(s.received, 2, "counters restart with the board")
        XCTAssertEqual(s.expected, 2)
        XCTAssertEqual(s.lost, 0, "a reboot must not be reported as 60k lost packets")
    }

    func testRateOverSlidingWindow() {
        var stats = LinkStats(rateWindow: 2.0)
        // 101 packets at exactly 10 ms spacing -> 100 Hz over 1.0 s
        for i in 0...100 {
            stats.record(seq: UInt16(i + 1), at: Double(i) * 0.01)
        }
        XCTAssertEqual(stats.snapshot.packetsPerSecond, 100.0, accuracy: 0.5)
    }

    func testRateIgnoresSamplesOlderThanWindow() {
        var stats = LinkStats(rateWindow: 1.0)
        stats.record(seq: 1, at: 0.0)         // ancient, must be pruned
        for i in 0...50 {
            stats.record(seq: UInt16(i + 2), at: 10.0 + Double(i) * 0.02)  // 50 Hz
        }
        XCTAssertEqual(stats.snapshot.packetsPerSecond, 50.0, accuracy: 1.0)
    }

    func testEmptyStatsAreZeroNotNaN() {
        let s = LinkStats().snapshot
        XCTAssertEqual(s.received, 0)
        XCTAssertEqual(s.expected, 0)
        XCTAssertEqual(s.lossFraction, 0.0)
        XCTAssertEqual(s.packetsPerSecond, 0.0)
        XCTAssertFalse(s.lossFraction.isNaN, "0/0 must not produce NaN")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ios/SensorCore && swift test --filter LinkStatsTests
```

Expected: compile failure, `cannot find 'LinkStats' in scope`.

- [ ] **Step 3: Implement `LinkStats`**

Create `ios/SensorCore/Sources/SensorCore/LinkStats.swift`:

```swift
import Foundation

/// Measures how much of a board's packet stream actually arrives.
///
/// Fed `(seq, arrivalTime)` pairs, it reports packet rate and loss. It knows
/// nothing about Bluetooth so it can be verified on a Mac against synthetic
/// input — which matters, because a loss figure you can only check by holding
/// two boards and squinting is not evidence.
///
/// `seq` is a `UInt16` that wraps every 65536 packets (~11 min at 100 Hz), so
/// all deltas are computed with wrapping arithmetic.
public struct LinkStats {

    public struct Snapshot: Equatable {
        public let received: Int
        public let expected: Int
        public let lost: Int
        public let lossFraction: Double
        public let packetsPerSecond: Double
        /// Increments when the board reboots (`seq` jumps backwards a long way).
        public let epochs: Int
    }

    /// A backwards jump of at most this many is late delivery, not a reboot.
    private static let reorderTolerance = 64
    /// Above this, a forward delta is really a backwards jump modulo 65536.
    private static let forwardLimit = 32768

    private let rateWindow: TimeInterval
    private var lastSeq: UInt16?
    private var received = 0
    private var expected = 0
    private var epochs = 0
    private var arrivals: [TimeInterval] = []

    public init(rateWindow: TimeInterval = 2.0) {
        self.rateWindow = rateWindow
    }

    public mutating func record(seq: UInt16, at time: TimeInterval) {
        defer { noteArrival(at: time) }

        guard let last = lastSeq else {
            startEpoch(at: seq)
            return
        }

        let fwd = Int(seq &- last)

        if fwd == 0 {
            received += 1                     // duplicate
        } else if fwd <= Self.forwardLimit {
            expected += fwd                   // normal step; fwd-1 were lost
            received += 1
            lastSeq = seq
        } else if 65536 - fwd <= Self.reorderTolerance {
            received += 1                     // arrived late, fills its own gap
        } else {
            arrivals.removeAll()              // board rebooted
            startEpoch(at: seq)
        }
    }

    public var snapshot: Snapshot {
        let lost = max(0, expected - received)
        return Snapshot(
            received: received,
            expected: expected,
            lost: lost,
            lossFraction: expected > 0 ? Double(lost) / Double(expected) : 0,
            packetsPerSecond: rate,
            epochs: epochs
        )
    }

    private mutating func startEpoch(at seq: UInt16) {
        lastSeq = seq
        received = 1
        expected = 1
        epochs += 1
    }

    private mutating func noteArrival(at time: TimeInterval) {
        arrivals.append(time)
        let cutoff = time - rateWindow
        if let keepFrom = arrivals.firstIndex(where: { $0 >= cutoff }), keepFrom > 0 {
            arrivals.removeFirst(keepFrom)
        }
    }

    private var rate: Double {
        guard let first = arrivals.first, let lastTime = arrivals.last,
              arrivals.count >= 2, lastTime > first else { return 0 }
        return Double(arrivals.count - 1) / (lastTime - first)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ios/SensorCore && swift test
```

Expected: all `LinkStatsTests` pass, and the 7 pre-existing `SensorPacketTests` / `CaptureWriterTests` still pass. Total 17 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ios/SensorCore/Sources/SensorCore/LinkStats.swift ios/SensorCore/Tests/SensorCoreTests/LinkStatsTests.swift
git commit -m "feat(ios): LinkStats — packet rate and loss from seq numbers

Wrap, reorder, duplicate, and board-reset all specified and tested, so a
displayed loss figure can be trusted without hardware in hand."
```

---

### Task 2: App project, workspace, and package dependency

Creating an `.xcodeproj` requires Xcode — it is a generated bundle, not authorable as text. **These steps are done by the user in the GUI**; everything afterwards is normal file editing.

**Files:**
- Create (via Xcode): `ios/TrackingApp/TrackingApp.xcodeproj`, `ios/TrackingSystem.xcworkspace`
- Create: `ios/README.md`
- Modify: `ios/TrackingApp/TrackingApp/Info.plist` (Bluetooth usage string)

**Interfaces:**
- Consumes: `SensorCore` from Task 1.
- Produces: an app target that builds and runs on a physical iPhone, with `import SensorCore` resolving.

- [ ] **Step 1: Create the app project (Xcode GUI)**

In Xcode: **File → New → Project → iOS → App**.
- Product Name: `TrackingApp`
- Interface: **SwiftUI**, Language: **Swift**
- Storage: **None**, uncheck Tests (the tests that matter live in `SensorCore`)
- Save into: `ios/TrackingApp/`

- [ ] **Step 2: Create the workspace and add both (Xcode GUI)**

**File → New → Workspace**, save as `ios/TrackingSystem.xcworkspace`. Then drag
`ios/TrackingApp/TrackingApp.xcodeproj` and the `ios/SensorCore` folder into it.

Close the standalone project window and work from the workspace from now on.

- [ ] **Step 3: Link SensorCore to the app target (Xcode GUI)**

Select the `TrackingApp` target → **General** → **Frameworks, Libraries, and Embedded Content** → **+** → choose the `SensorCore` library.

Then set signing: target → **Signing & Capabilities** → check **Automatically manage signing** → pick your personal team. Bundle identifier must be unique (e.g. `com.<yourname>.trackingapp`).

- [ ] **Step 4: Add the Bluetooth usage string**

iOS kills the app on first CoreBluetooth use if this key is missing. In the target's **Info** tab add:

- Key: `Privacy - Bluetooth Always Usage Description` (`NSBluetoothAlwaysUsageDescription`)
- Value: `Connects to the DWM tags to read motion and distance data.`

- [ ] **Step 5: Verify the app builds and launches on the phone**

Plug in the iPhone, select it as the run destination, press Run.

Expected: the stock "Hello, world!" SwiftUI screen appears on the device. On first run you must trust the developer certificate: **Settings → General → VPN & Device Management → your Apple ID → Trust**.

- [ ] **Step 6: Verify `import SensorCore` resolves**

Replace the body of `ios/TrackingApp/TrackingApp/ContentView.swift` with:

```swift
import SwiftUI
import SensorCore

struct ContentView: View {
    var body: some View {
        Text("SensorCore linked: \(SensorPacket.byteCount) byte packets")
            .padding()
    }
}
```

Run again. Expected on device: **"SensorCore linked: 16 byte packets"**. If this fails to compile, the package link in Step 3 did not take.

- [ ] **Step 7: Write `ios/README.md`**

```markdown
# iOS — TrackingSystem

Open **`TrackingSystem.xcworkspace`**, not the project file.

```
SensorCore/     Swift package: packet decode, link stats, CSV rows.
                Pure Foundation — no CoreBluetooth, so `swift test` runs on a Mac.
TrackingApp/    The iOS app. CoreBluetooth + SwiftUI. Device only.
```

## Running the tests

```bash
cd ios/SensorCore && swift test
```

No hardware needed. This is where the link-measurement logic is verified.

## Deploying to the phone

CoreBluetooth does nothing in the Simulator — there is no radio. Everything
below needs a physical iPhone.

Signing uses **free provisioning**, so **builds stop launching after 7 days**.
Re-deploy from Xcode before a measurement session; a stale build failing to
open is expected, not a bug.

First run on a new device: **Settings → General → VPN & Device Management →
trust the developer certificate.**

## Boards

Both tags must be powered and flashed with the sensor-stream firmware. They
advertise as `DWM-INIT` and `DWM-RESP`. Only `DWM-INIT` reports a distance;
`DWM-RESP` always sends the sentinel, which the decoder turns into `nil`.
See `firmware/ble-contract.md`.
```

- [ ] **Step 8: Commit**

```bash
git add ios/
git commit -m "chore(ios): app project, workspace, and SensorCore dependency

Workspace ties the package and app together; SensorCore stays standalone so
its tests keep running on macOS without a phone."
```

---

### Task 3: `BoardLink` — CoreBluetooth adapter

One instance per board. It scans, connects, subscribes, and forwards raw bytes with an arrival timestamp. It does no arithmetic — that is Task 1's job.

**Files:**
- Create: `ios/TrackingApp/TrackingApp/BoardLink.swift`

**Interfaces:**
- Consumes: `SensorPacket(_ data: Data)` and `LinkStats` from `SensorCore`.
- Produces:
  - `enum BoardRole: String { case initiator = "DWM-INIT", responder = "DWM-RESP" }`
  - `final class BoardLink: NSObject` with `init(role: BoardRole, onPacket: @escaping (SensorPacket, TimeInterval) -> Void, onState: @escaping (String) -> Void)`
  - `func start()`
  - `var disconnectCount: Int`

- [ ] **Step 1: Write `BoardLink`**

```swift
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
    private(set) var disconnectCount = 0

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
        case .poweredOn: scan()
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
        disconnectCount += 1
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
```

- [ ] **Step 2: Verify it compiles**

Build the app target in Xcode (⌘B).

Expected: build succeeds. Nothing observable changes yet — `BoardLink` has no caller until Task 4.

- [ ] **Step 3: Commit**

```bash
git add ios/TrackingApp/TrackingApp/BoardLink.swift
git commit -m "feat(ios): BoardLink — CoreBluetooth adapter per board

Scans by service UUID, identifies the tag by advertised name, subscribes to
the sensor characteristic, auto-reconnects. Forwards decoded packets with an
arrival timestamp and computes nothing itself."
```

---

### Task 4: `BoardModel` — state, throttled to 10 Hz

Two boards at 100 Hz is ~200 callbacks a second. Publishing each one to SwiftUI would make the app a source of the loss it is measuring. Packets update plain state on the BLE queue; a 10 Hz timer publishes a snapshot on the main thread.

**Files:**
- Create: `ios/TrackingApp/TrackingApp/BoardModel.swift`

**Interfaces:**
- Consumes: `BoardLink`, `BoardRole` (Task 3); `LinkStats`, `SensorPacket` (Task 1).
- Produces:
  - `@Observable final class BoardModel` with `let role: BoardRole`, `var state: String`, `var stats: LinkStats.Snapshot`, `var latest: SensorPacket?`, `var disconnects: Int`
  - `func start()`
  - `@Observable final class AppModel` with `let boards: [BoardModel]`, `func start()`

- [ ] **Step 1: Write `BoardModel`**

```swift
import Foundation
import Observation
import SensorCore

/// Live state for one board, published to the view at a fixed 10 Hz.
///
/// Packets land on the BLE queue at ~100 Hz and mutate `pending` under a lock.
/// A timer copies that into the observable properties on the main thread. The
/// radio rate and the render rate stay independent — and 10 Hz is already
/// faster than anyone reads a changing number.
@Observable
final class BoardModel {

    let role: BoardRole

    var state: String = "starting"
    var stats: LinkStats.Snapshot = LinkStats().snapshot
    var latest: SensorPacket?
    var disconnects: Int = 0

    @ObservationIgnored private var link: BoardLink?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var pendingStats = LinkStats()
    @ObservationIgnored private var pendingPacket: SensorPacket?
    @ObservationIgnored private var pendingState = "starting"
    @ObservationIgnored private var timer: Timer?

    init(role: BoardRole) {
        self.role = role
    }

    func start() {
        let link = BoardLink(
            role: role,
            onPacket: { [weak self] packet, arrival in
                guard let self else { return }
                self.lock.lock()
                self.pendingStats.record(seq: packet.seq, at: arrival)
                self.pendingPacket = packet
                self.lock.unlock()
            },
            onState: { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                self.pendingState = state
                self.lock.unlock()
            })
        self.link = link
        link.start()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    private func publish() {
        lock.lock()
        let snapshot = pendingStats.snapshot
        let packet = pendingPacket
        let state = pendingState
        lock.unlock()

        self.stats = snapshot
        self.latest = packet
        self.state = state
        self.disconnects = link?.disconnectCount ?? 0
    }
}

/// Owns one model per board. Both run independently, so one missing tag
/// never blocks the other.
@Observable
final class AppModel {
    let boards: [BoardModel] = BoardRole.allCases.map(BoardModel.init(role:))

    func start() {
        boards.forEach { $0.start() }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Build in Xcode (⌘B). Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/TrackingApp/TrackingApp/BoardModel.swift
git commit -m "feat(ios): BoardModel — per-board state published at 10 Hz

Decouples the ~200/sec BLE callback rate from SwiftUI rendering so the app
can't become a source of the loss it's measuring."
```

---

### Task 5: `LiveView` — the screen

**Files:**
- Create: `ios/TrackingApp/TrackingApp/LiveView.swift`
- Modify: `ios/TrackingApp/TrackingApp/ContentView.swift` (replace the Task 2 placeholder)
- Modify: `ios/TrackingApp/TrackingApp/TrackingAppApp.swift` (own the `AppModel`)

**Interfaces:**
- Consumes: `AppModel`, `BoardModel` (Task 4).
- Produces: `struct LiveView: View`.

Accel raw counts are left-justified 12-bit at ±2 g, so `Double(raw) / 16384.0` gives g — matching `firmware/ble-contract.md` (~±0.98 g on the down axis at rest).

- [ ] **Step 1: Write `LiveView`**

```swift
import SwiftUI
import SensorCore

struct LiveView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List(model.boards, id: \.role) { board in
                BoardPanel(board: board)
            }
            .navigationTitle("Tags")
        }
    }
}

private struct BoardPanel: View {
    let board: BoardModel

    var body: some View {
        Section {
            row("rate", String(format: "%.1f /s", board.stats.packetsPerSecond))
            row("loss", String(format: "%.2f %%  (%d of %d)",
                               board.stats.lossFraction * 100,
                               board.stats.lost,
                               board.stats.expected))
            row("accel", accelText)
            row("dist", distText)
            if board.disconnects > 0 {
                row("drops", "\(board.disconnects)")
            }
        } header: {
            HStack {
                Text(board.role.rawValue)
                Spacer()
                Text(board.state).foregroundStyle(.secondary)
            }
            .font(.headline)
            .textCase(nil)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    /// Raw counts are left-justified 12-bit at +-2 g: 16384 counts per g.
    private var accelText: String {
        guard let p = board.latest else { return "—" }
        let g = { (raw: Int16) in Double(raw) / 16384.0 }
        return String(format: "%+.2f  %+.2f  %+.2f g", g(p.ax), g(p.ay), g(p.az))
    }

    private var distText: String {
        guard let p = board.latest else { return "—" }
        guard let mm = p.uwbMm else { return "—" }
        return "\(mm) mm"
    }
}
```

- [ ] **Step 2: Wire it up**

Replace `ContentView.swift` entirely:

```swift
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        LiveView(model: model)
    }
}
```

And in `TrackingAppApp.swift`:

```swift
import SwiftUI

@main
struct TrackingAppApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
    }
}
```

- [ ] **Step 3: Run on the device with both boards powered**

Expected: two sections, `DWM-INIT` and `DWM-RESP`, both reaching `streaming`
within a few seconds. Rate settles near 100 /s each. Moving a board changes
that board's accel row. `DWM-INIT` shows a distance in mm; `DWM-RESP` shows `—`.

If a board never leaves `searching`: confirm it is powered and advertising by
checking it appears in nRF Connect.

- [ ] **Step 4: Commit**

```bash
git add ios/TrackingApp/TrackingApp/
git commit -m "feat(ios): live view — per-board rate, loss, accel, distance

Numbers only. Judging the accel signal happens on exported CSV in M4."
```

---

### Task 6: Measure, and record the result

The milestone's actual deliverable.

**Files:**
- Modify: `docs/architecture.md` (roadmap row + decision log entry)

- [ ] **Step 1: Run the 5-minute measurement**

Both boards powered, phone connected to both, app foregrounded, screen on, boards
roughly at wear separation (~1 m). Leave it for 5 minutes without touching it.

Record for each board: final rate (/s), loss %, lost/expected counts, disconnects,
and `epochs` if it exceeded 1.

- [ ] **Step 2: Sanity-check the numbers before believing them**

- Does `expected` ≈ 5 min × 100 Hz ≈ 30,000? If it is wildly under, the boards are
  not sampling at 100 Hz and the problem is upstream of the link.
- Did `epochs` stay at 1? More than 1 means a board reset mid-run — note it, since
  it invalidates a continuous-loss reading across the boundary.
- Do the two boards broadly agree? A large asymmetry points at one board or its
  connection parameters, not at BLE in general.

- [ ] **Step 3: Record the result in `architecture.md`**

Add to the decision log, filling in the measured values:

```markdown
- **2026-07-__ — M3a verified.** iOS app connects to both tags and reports live
  rate and loss.
  - **DWM-INIT:** __ /s, __ % loss (__ of __), __ disconnects
  - **DWM-RESP:** __ /s, __ % loss (__ of __), __ disconnects
  - Measured over a __-minute foreground run at ~1 m separation.
  - **No bar was set** (ADR-5): the figure is the baseline. [Interpretation:
    whether this is fine, or worth a firmware follow-up on `sd_ble_gatts_hvx`
    back-pressure / connection interval.]
```

And flip the roadmap row for M3a to `✅ verified`, marking M3b as next.

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: M3a verified — measured BLE rate and loss

First real figure for what fraction of the 100 Hz stream reaches the phone."
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §1 goal — connect both, show state/rate/loss/accel/distance | 3, 4, 5 |
| §3 criterion — 5-min run, figures in architecture.md, no bar | 6 |
| §4.0 repo layout — package + app + workspace under `ios/` | 2 |
| §4 module boundary — `LinkStats` pure, no CoreBluetooth | 1 |
| §4.1 scan by UUID, identify by name, degrade, auto-reconnect | 3 |
| §4.2 10 Hz publish decoupled from packet rate | 4 |
| §4.3 wrap / reboot / reorder / disconnects counted separately | 1 (wrap, reboot, reorder), 3 + 4 (disconnects) |
| §5 free provisioning, device-only | 2 (README, signing) |
| §6 `LinkStats` unit tests — all six named cases | 1 |
| §6 device test — states, accel responds, `uwb_mm` only on INIT | 5 step 3 |
| §7 out of scope — no recording, CSV, plots, firmware changes | not implemented anywhere ✅ |

**Type consistency:** `LinkStats.Snapshot` field names (`received`, `expected`, `lost`, `lossFraction`, `packetsPerSecond`, `epochs`) are used identically in Tasks 1, 4, and 5. `BoardRole.rawValue` is the advertised name in both Task 3 (matching) and Task 5 (display). `SensorPacket.uwbMm` is `UInt32?` per the existing source, unwrapped with `guard let` in Task 5.

**Placeholders:** none. The only blanks are the measured values in Task 6, which are blank because measuring them is the point.
