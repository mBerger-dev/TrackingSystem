# M3b Capture Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a foreground session from both tags into one combined CSV and share it off the phone in one tap.

**Architecture:** A pure-Foundation `CaptureSession` in `SensorCore` streams CSV rows to a file on its own serial queue (testable on macOS). An app-side `@Observable` `RecordingController` owns Start/Stop, filenames, the sessions list, and share/delete. Both `BoardModel`s forward every packet to the controller at the full 100 Hz, before the 10 Hz UI throttle. A `scenePhase` observer auto-stops on background.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation framework, Foundation `FileHandle`/`DispatchQueue`, CoreBluetooth (existing). Firmware prerequisite in C (Qorvo DW3000 API).

## Global Constraints

- **CSV columns are frozen:** `board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm` — produced only via the existing `CaptureWriter`; never hand-format a row.
- **`SensorCore` stays pure Foundation** — no CoreBluetooth, no UIKit/SwiftUI, no hard-coded file locations. It is handed a URL. This is what keeps `swift test` runnable on the Mac.
- **iOS 17+** — the app uses the Observation framework (`@Observable`, `@Bindable`) and the two-parameter `onChange`.
- **Open `ios/TrackingSystem.xcworkspace`, never the `.xcodeproj`.**
- **Trust `xcodebuild` over the editor** — SourceKit reports bogus `No such module 'SensorCore'` errors in this project.
- **Free provisioning** — device builds stop launching after 7 days; re-deploy before any device run.
- Board roles advertise as `DWM-INIT` / `DWM-RESP`; `BoardRole.rawValue` is exactly those strings and is used as the CSV `board` value.

---

### Task 0: Prerequisite — bound the UWB status wait (§9.2 firmware fix)

Independent firmware change. **Do this on its own branch off `main` (`fix/uwb-starttx-bounded-wait`) and merge it before the Task 5 device run.** The iOS tasks (1–4) do not depend on it and proceed on `feat/m3b-capture-recording`.

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c` (the `dwt_starttx(...)` call in `ranging_exchange()` and the `waitforsysstatus(...)` that follows it, ~line 230)

**Interfaces:**
- Consumes: `dwt_starttx`, `dwt_readsysstatuslo`, `dwt_writesysstatuslo`, `DWT_SUCCESS`, `DWT_INT_RXFCG_BIT_MASK`, `SYS_STATUS_ALL_RX_TO`, `SYS_STATUS_ALL_RX_ERR` (Qorvo DW3000 API, already used in this file). If `DWT_SUCCESS` is not visible, it lives in `deca_device_api.h`.
- Produces: no signature change — `ranging_exchange(uint32_t *out_mm)` still returns `bool` (false ⇒ caller emits the `0xFFFFFFFF` sentinel).

- [ ] **Step 1: Add the spin-bound constant near the top of `ranging.c`** (below the existing `#include`s / `#define`s)

```c
/* Safety bound for the post-TX status wait (architecture.md §9.2). The DW3000's
 * own RX timeout normally sets a status bit far below this; the cap only trips
 * when TX silently failed to start, so no RX window — and no timeout bit — opens. */
#define RANGING_STATUS_MAX_SPINS 200000u
```

- [ ] **Step 2: Replace the unchecked TX + unbounded wait in `ranging_exchange()`**

Find:

```c
    dwt_starttx(DWT_START_TX_IMMEDIATE | DWT_RESPONSE_EXPECTED);

    uint32_t status_reg = 0;
    waitforsysstatus(&status_reg, NULL,
                     (DWT_INT_RXFCG_BIT_MASK | SYS_STATUS_ALL_RX_TO | SYS_STATUS_ALL_RX_ERR), 0);
    frame_seq_nb++;
```

Replace with:

```c
    if (dwt_starttx(DWT_START_TX_IMMEDIATE | DWT_RESPONSE_EXPECTED) != DWT_SUCCESS)
    {
        frame_seq_nb++;
        return false;              /* TX never started -> sentinel, don't spin */
    }

    const uint32_t status_mask =
        (DWT_INT_RXFCG_BIT_MASK | SYS_STATUS_ALL_RX_TO | SYS_STATUS_ALL_RX_ERR);
    uint32_t status_reg = 0;
    uint32_t spins = 0;
    while (!((status_reg = dwt_readsysstatuslo()) & status_mask))
    {
        if (++spins >= RANGING_STATUS_MAX_SPINS)
        {
            dwt_writesysstatuslo(SYS_STATUS_ALL_RX_TO | SYS_STATUS_ALL_RX_ERR);
            frame_seq_nb++;
            return false;          /* stuck radio -> sentinel, don't spin forever */
        }
    }
    frame_seq_nb++;
```

The existing `if (!(status_reg & DWT_INT_RXFCG_BIT_MASK)) { ... }` block immediately below is unchanged and still runs on the normal path.

- [ ] **Step 3: Build the firmware**

Run: `cd firmware/DWM3001C-starter-firmware && make build`
Expected: build completes; `Output/Common/Exe/dw3000_api.hex` produced. (No `emProject` edit is needed — no files were added/removed — so no `make clean` required.)

- [ ] **Step 4: Hardware regression check**

Flash the initiator image to a board (see `firmware/FLASHING.md` / `firmware/roles.md`; flash from the host with `JLinkExe loadfile`, SoftDevice + app). With both tags running, confirm over RTT / the phone that real distances still stream and the initiator does **not** stall. The infinite-spin path is hard to force deliberately; verification is (a) normal ranging still works and (b) the two new guards are present.

- [ ] **Step 5: Commit (on `fix/uwb-starttx-bounded-wait`)**

```bash
git add firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c
git commit -m "fix(fw): bound the UWB status wait and check dwt_starttx (§9.2)"
```

Then open a PR, merge to `main`, and continue the iOS work below.

---

### Task 1: `CaptureSession` — streaming CSV writer (SensorCore)

**Files:**
- Create: `ios/SensorCore/Sources/SensorCore/CaptureSession.swift`
- Test: `ios/SensorCore/Tests/SensorCoreTests/CaptureSessionTests.swift`

**Interfaces:**
- Consumes: `CaptureWriter.header() -> String`; `CaptureWriter.row(board: String, phoneArrivalMs: Int64, _ p: SensorPacket) -> String`; `SensorPacket`.
- Produces:
  - `CaptureSession(url: URL)`
  - `func start() throws` — creates the file and writes `header() + "\n"` once
  - `func append(board: String, phoneArrivalMs: Int64, packet: SensorPacket)` — enqueues one row (async, non-blocking)
  - `func close()` — flushes and closes, idempotent
  - `var rowCount: Int` — data rows written so far
  - `var countsByBoard: [String: Int]` — rows per `board` value

- [ ] **Step 1: Write the failing test**

Create `ios/SensorCore/Tests/SensorCoreTests/CaptureSessionTests.swift`:

```swift
import XCTest
@testable import SensorCore

final class CaptureSessionTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
    }

    private func packet(seq: UInt16, boardTimeMs: UInt32 = 0,
                        ax: Int16 = 0, ay: Int16 = 0, az: Int16 = 0,
                        uwbMm: UInt32 = 0xFFFF_FFFF) -> SensorPacket {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
             UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        var b: [UInt8] = []
        b += le16(seq); b += le32(boardTimeMs)
        b += le16(UInt16(bitPattern: ax))
        b += le16(UInt16(bitPattern: ay))
        b += le16(UInt16(bitPattern: az))
        b += le32(uwbMm)
        return SensorPacket(Data(b))!
    }

    private func read(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testStartWritesHeaderOnceAndNoRows() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines, [CaptureWriter().header()])
        XCTAssertEqual(s.rowCount, 0)
    }

    func testAppendWritesOneRowPerPacket() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 0, packet: packet(seq: 1))
        s.append(board: "DWM-INIT", phoneArrivalMs: 10, packet: packet(seq: 2))
        s.append(board: "DWM-INIT", phoneArrivalMs: 20, packet: packet(seq: 3))
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines.count, 4, "header + 3 rows")
        XCTAssertEqual(s.rowCount, 3)
    }

    func testRowMatchesCaptureWriter() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        let p = packet(seq: 42, boardTimeMs: 1234, ax: -320, ay: 80, az: 16384, uwbMm: 1454)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 7, packet: p)
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines[1],
            CaptureWriter().row(board: "DWM-INIT", phoneArrivalMs: 7, p))
    }

    func testBothBoardsInterleaveAndCount() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 0, packet: packet(seq: 1))
        s.append(board: "DWM-RESP", phoneArrivalMs: 1, packet: packet(seq: 5))
        s.append(board: "DWM-INIT", phoneArrivalMs: 2, packet: packet(seq: 2))
        s.close()
        let lines = read(url)
        XCTAssertTrue(lines[1].hasPrefix("DWM-INIT,"))
        XCTAssertTrue(lines[2].hasPrefix("DWM-RESP,"))
        XCTAssertTrue(lines[3].hasPrefix("DWM-INIT,"))
        XCTAssertEqual(s.countsByBoard, ["DWM-INIT": 2, "DWM-RESP": 1])
    }

    func testCloseIsIdempotent() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.close()
        s.close()   // must not crash
        XCTAssertEqual(read(url), [CaptureWriter().header()])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/SensorCore && swift test --filter CaptureSessionTests`
Expected: FAIL — `cannot find 'CaptureSession' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/SensorCore/Sources/SensorCore/CaptureSession.swift`:

```swift
import Foundation

/// Streams decoded packets to a CSV file, one row per packet.
///
/// Pure Foundation and handed a URL, so it is verified on a Mac against a temp
/// file rather than by holding two boards. Writes happen on a dedicated serial
/// queue, so appending never blocks the caller's thread (the BLE queues).
public final class CaptureSession {

    private let url: URL
    private let writer = CaptureWriter()
    private let queue = DispatchQueue(label: "capture.session.write")
    private var handle: FileHandle?
    private var closed = false
    private var _rowCount = 0
    private var _countsByBoard: [String: Int] = [:]

    public init(url: URL) { self.url = url }

    /// Creates the file and writes the CSV header exactly once.
    public func start() throws {
        let header = writer.header() + "\n"
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
    }

    /// Enqueues one row. Non-blocking; ordering follows call order (FIFO queue).
    public func append(board: String, phoneArrivalMs: Int64, packet: SensorPacket) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle, !self.closed else { return }
            let line = self.writer.row(board: board, phoneArrivalMs: phoneArrivalMs, packet) + "\n"
            try? handle.write(contentsOf: Data(line.utf8))
            self._rowCount += 1
            self._countsByBoard[board, default: 0] += 1
        }
    }

    /// Flushes queued writes and closes the file. Safe to call more than once.
    public func close() {
        queue.sync {
            guard !closed else { return }
            try? handle?.close()
            handle = nil
            closed = true
        }
    }

    public var rowCount: Int { queue.sync { _rowCount } }
    public var countsByBoard: [String: Int] { queue.sync { _countsByBoard } }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/SensorCore && swift test`
Expected: PASS — all `CaptureSessionTests` plus the existing 24 tests (28 total).

- [ ] **Step 5: Commit**

```bash
git add ios/SensorCore/Sources/SensorCore/CaptureSession.swift \
        ios/SensorCore/Tests/SensorCoreTests/CaptureSessionTests.swift
git commit -m "feat(ios): CaptureSession — streaming CSV writer for recordings"
```

---

### Task 2: `RecordingController` — start/stop, files, sessions (TrackingApp)

No unit-test target exists for the app; the gate is a clean `xcodebuild`. Keep logic thin — the writing lives in the tested `CaptureSession`.

**Files:**
- Create: `ios/TrackingApp/TrackingApp/RecordingController.swift`

**Interfaces:**
- Consumes: `CaptureSession` (Task 1); `BoardRole` (exists, `rawValue` = `"DWM-INIT"`/`"DWM-RESP"`); `SensorPacket`.
- Produces:
  - `RecordingController()` (`@Observable`)
  - observable: `isRecording: Bool`, `label: String`, `elapsed: TimeInterval`, `totalRows: Int`, `countsByBoard: [String: Int]`, `sessions: [RecordedSession]`
  - `func start()`, `func stop()`
  - `func append(role: BoardRole, packet: SensorPacket, arrival: TimeInterval)` — no-op unless recording
  - `func delete(_ session: RecordedSession)`
  - `struct RecordedSession: Identifiable { let id: URL; let name: String; let rowCount: Int; var url: URL }`

- [ ] **Step 1: Write the implementation**

Create `ios/TrackingApp/TrackingApp/RecordingController.swift`:

```swift
import Foundation
import Observation
import SensorCore

/// A finished recording on disk.
struct RecordedSession: Identifiable {
    let id: URL
    let name: String
    let rowCount: Int
    var url: URL { id }
}

/// Owns the active recording and the list of finished ones. Device-specific
/// (Documents directory, share); the CSV writing lives in `CaptureSession`.
@Observable
final class RecordingController {

    var isRecording = false
    var label = "session"
    var elapsed: TimeInterval = 0
    var totalRows = 0
    var countsByBoard: [String: Int] = [:]
    var sessions: [RecordedSession] = []

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var startUptime: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?

    init() { refreshSessions() }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard !isRecording else { return }
        let url = documentsURL.appendingPathComponent(Self.fileName(label: label))
        let session = CaptureSession(url: url)
        do { try session.start() } catch { return }

        lock.lock()
        self.session = session
        self.startUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        isRecording = true
        elapsed = 0
        totalRows = 0
        countsByBoard = [:]

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from the BLE queues at ~100 Hz per board. No-op unless recording.
    func append(role: BoardRole, packet: SensorPacket, arrival: TimeInterval) {
        lock.lock()
        let session = self.session
        let start = self.startUptime
        lock.unlock()
        guard let session else { return }
        let ms = Int64((arrival - start) * 1000)
        session.append(board: role.rawValue, phoneArrivalMs: ms, packet: packet)
    }

    func stop() {
        guard isRecording else { return }
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.close()
        timer?.invalidate()
        timer = nil
        isRecording = false
        refreshSessions()
    }

    func delete(_ session: RecordedSession) {
        try? FileManager.default.removeItem(at: session.url)
        refreshSessions()
    }

    private func tick() {
        lock.lock()
        let session = self.session
        let start = self.startUptime
        lock.unlock()
        guard let session else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - start
        totalRows = session.rowCount
        countsByBoard = session.countsByBoard
    }

    private func refreshSessions() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let csvs = urls.filter { $0.pathExtension == "csv" }
        let sorted = csvs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
        sessions = sorted.map {
            RecordedSession(id: $0, name: $0.lastPathComponent, rowCount: Self.countRows($0))
        }
    }

    private static func countRows(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return max(0, lines.count - 1)   // minus the header
    }

    private static func fileName(label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.map { "/: ".contains($0) ? "-" : $0 }
        let base = cleaned.isEmpty ? "session" : String(cleaned)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(base)-\(fmt.string(from: Date())).csv"
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd ios && xcodebuild -workspace TrackingSystem.xcworkspace -scheme TrackingApp \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. (Ignore any SourceKit `No such module 'SensorCore'` editor noise.)

- [ ] **Step 3: Commit**

```bash
git add ios/TrackingApp/TrackingApp/RecordingController.swift
git commit -m "feat(ios): RecordingController — start/stop, filenames, sessions"
```

---

### Task 3: Wire the packet tap and auto-stop on background

**Files:**
- Modify: `ios/TrackingApp/TrackingApp/BoardModel.swift` (add a `recorder` reference; feed it in `onPacket`; construct `AppModel.boards` with the shared controller)
- Modify: `ios/TrackingApp/TrackingApp/TrackingAppApp.swift` (auto-stop on background)

**Interfaces:**
- Consumes: `RecordingController.append(role:packet:arrival:)`, `RecordingController()` (Task 2).
- Produces: `AppModel.recording: RecordingController` (read by the views in Task 4); `BoardModel(role:recorder:)`.

- [ ] **Step 1: Give `BoardModel` a recorder and feed it**

In `ios/TrackingApp/TrackingApp/BoardModel.swift`, change the stored properties and `init`:

```swift
    let role: BoardRole
    @ObservationIgnored private let recorder: RecordingController

    // ... existing observable/@ObservationIgnored properties unchanged ...

    init(role: BoardRole, recorder: RecordingController) {
        self.role = role
        self.recorder = recorder
    }
```

Then in `start()`, add the recorder feed as the first line of the `onPacket` closure (outside the lock — the controller is internally synchronized):

```swift
            onPacket: { [weak self] packet, arrival in
                guard let self else { return }
                self.recorder.append(role: self.role, packet: packet, arrival: arrival)
                self.lock.lock()
                self.pendingStats.record(seq: packet.seq, at: arrival)
                self.pendingPacket = packet
                self.lock.unlock()
            },
```

- [ ] **Step 2: Give `AppModel` the shared controller and pass it to each board**

In the same file, replace the `AppModel` type with:

```swift
@Observable
final class AppModel {
    let recording = RecordingController()
    let boards: [BoardModel]

    @ObservationIgnored private var started = false

    init() {
        let recording = self.recording
        boards = BoardRole.allCases.map { BoardModel(role: $0, recorder: recording) }
    }

    func start() {
        guard !started else { return }
        started = true
        boards.forEach { $0.start() }
    }
}
```

- [ ] **Step 3: Auto-stop the recording when the app is backgrounded**

Replace `ios/TrackingApp/TrackingApp/TrackingAppApp.swift` with:

```swift
import SwiftUI

@main
struct TrackingAppApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground-only for now: finalize the file rather than record blind.
            if phase == .background { model.recording.stop() }
        }
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd ios && xcodebuild -workspace TrackingSystem.xcworkspace -scheme TrackingApp \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/TrackingApp/TrackingApp/BoardModel.swift \
        ios/TrackingApp/TrackingApp/TrackingAppApp.swift
git commit -m "feat(ios): tap packets into the recorder; auto-stop on background"
```

---

### Task 4: Record bar and sessions list (LiveView)

**Files:**
- Modify: `ios/TrackingApp/TrackingApp/LiveView.swift`

**Interfaces:**
- Consumes: `AppModel.recording`, `RecordingController` observable properties and `start()`/`stop()`/`delete(_:)`, `RecordedSession` (Task 2/3).
- Produces: UI only.

- [ ] **Step 1: Add the record bar and sessions section**

In `ios/TrackingApp/TrackingApp/LiveView.swift`, replace the `LiveView` body's `List` so it includes the new sections, and add the two private views. The `LiveView` struct becomes:

```swift
struct LiveView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                RecordBar(rec: model.recording)
                ForEach(model.boards, id: \.role) { board in
                    BoardPanel(board: board)
                }
                SessionsSection(rec: model.recording)
            }
            .navigationTitle("Tags")
        }
    }
}
```

Append these two private views to the same file (leave `BoardPanel` as-is):

```swift
private struct RecordBar: View {
    @Bindable var rec: RecordingController

    var body: some View {
        Section {
            if rec.isRecording {
                HStack {
                    Label(rec.label, systemImage: "record.circle")
                        .foregroundStyle(.red)
                    Spacer()
                    Text(Self.time(rec.elapsed)).monospacedDigit()
                    Button("Stop", role: .destructive) { rec.stop() }
                        .buttonStyle(.borderedProminent)
                }
                Text(rowSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                HStack {
                    TextField("label", text: $rec.label)
                        .textInputAutocapitalization(.never)
                    Button("Start") { rec.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var rowSummary: String {
        let init_ = rec.countsByBoard["DWM-INIT"] ?? 0
        let resp = rec.countsByBoard["DWM-RESP"] ?? 0
        return "\(rec.totalRows) rows  ·  INIT \(init_) / RESP \(resp)"
    }

    private static func time(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct SessionsSection: View {
    @Bindable var rec: RecordingController

    var body: some View {
        if !rec.sessions.isEmpty {
            Section("Sessions") {
                ForEach(rec.sessions) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.subheadline)
                            Text("\(s.rowCount) rows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: s.url)
                    }
                }
                .onDelete { offsets in
                    offsets.map { rec.sessions[$0] }.forEach(rec.delete)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd ios && xcodebuild -workspace TrackingSystem.xcworkspace -scheme TrackingApp \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/TrackingApp/TrackingApp/LiveView.swift
git commit -m "feat(ios): live view — record bar, monitor, and sessions list"
```

---

### Task 5: Device acceptance run

Requires a physical iPhone, both tags powered and flashed (initiator on the Task 0 firmware), and a fresh deploy (free provisioning).

**Files:** none — this is verification.

- [ ] **Step 1: Deploy and record**

Deploy `TrackingApp` from Xcode to the phone. Wait for both panels to read `streaming`. Type a label (e.g. `squat`), press **Start**, move both tags for ~1–2 minutes, press **Stop**.

- [ ] **Step 2: Verify the live monitor behaved**

Confirm during recording that the elapsed timer advanced and the row counter climbed at roughly 200/s (≈100 per board). Confirm the finished session appeared in the **Sessions** list with a plausible row count.

- [ ] **Step 3: Share and inspect on the Mac**

Tap **Share** on the session → AirDrop to the Mac. Open the CSV and confirm:
- first line is exactly `board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm`
- both `DWM-INIT` and `DWM-RESP` rows are present
- `seq` is monotonic per board (allowing for the known ~0.5–0.9% gaps)
- `uwb_mm` is filled on `DWM-INIT` rows and blank on `DWM-RESP` rows
- `phone_arrival_ms` starts near 0 and increases
- row count ≈ observed rate × duration

- [ ] **Step 4: Verify auto-stop on background**

Start a new recording, then send the app to the background (Home / app switcher). Re-open it: recording is stopped and the partial session is in the list, openable and non-corrupt.

- [ ] **Step 5: Record the result**

Add a short M3b entry to `docs/architecture.md` (§6 roadmap / a note): confirmed a clean combined-CSV capture and share, with the observed row counts. Commit:

```bash
git add docs/architecture.md
git commit -m "docs: M3b verified — combined-CSV capture, share, auto-stop"
```

---

## Self-Review

**Spec coverage:**
- §1 goal (one shareable combined CSV) → Tasks 1–5.
- §2 scope: foreground record, manual start/stop → Tasks 2–4; combined CSV → Task 1; share sheet → Task 4 (`ShareLink`); delete → Tasks 2/4. Out-of-scope items are not built.
- §2.1 prerequisite §9.2 → Task 0.
- §3 done criteria: off-hardware `CaptureSession` tests → Task 1; device criteria → Task 5.
- §4.1 `CaptureSession` (pure, serial queue, reuses `CaptureWriter`) → Task 1.
- §4.2 `RecordingController` (start/stop, filename, Documents, append no-op, stop, sessions, delete) → Task 2.
- §4.3 100 Hz tap before UI throttle, serial-queue writes, disconnect not special-cased → Task 3 (tap) + Task 1 (queue). Disconnect needs no code — asserted by design and observable in Task 5.
- §4.4 auto-stop on background → Task 3, Step 3; verified Task 5, Step 4.
- §5 UI (record bar with live counter, sessions list with share, swipe-delete) → Task 4.
- §6 risks: append never blocks on I/O (`queue.async`) → Task 1; free provisioning / Simulator noted in Global Constraints and Task 5.

**Placeholder scan:** none — every code and command step is concrete.

**Type consistency:** `CaptureSession(url:)`, `start() throws`, `append(board:phoneArrivalMs:packet:)`, `close()`, `rowCount`, `countsByBoard` are identical across Tasks 1–3. `RecordingController.append(role:packet:arrival:)`, `start()`, `stop()`, `delete(_:)`, `RecordedSession(id:name:rowCount:)` match across Tasks 2–4. `CaptureWriter.row(board:phoneArrivalMs:_:)` matches the existing source. `BoardModel(role:recorder:)` matches its construction in `AppModel.init`.
