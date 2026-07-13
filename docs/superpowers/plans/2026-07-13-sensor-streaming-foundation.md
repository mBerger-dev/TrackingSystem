# Sensor Streaming Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get both DWM3001CDK boards streaming 3-axis acceleration + UWB inter-board distance over BLE to an iOS app that timestamps, displays, records, and exports raw data.

**Architecture:** Two boards run UWB two-way ranging with each other (one initiator, one responder) and each reads its own LIS2DH12 accelerometer. Each board is an independent BLE peripheral. An iPhone acts as BLE central, connects to both, parses packets, adds arrival timestamps, and writes labeled CSV captures.

**Tech Stack:** Firmware in C on the community `Uberi/DWM3001C-starter-firmware` base (Docker build, host-side flash via SEGGER J-Link + Nordic `nrfjprog`). iOS app in Swift + CoreBluetooth (Xcode). Analysis via exported CSV on a laptop.

## Global Constraints

- **Host OS for this work:** macOS (darwin). Docker-on-Mac cannot pass USB through to the container, so **all flashing and serial-log commands run on the macOS host**, not inside Docker. Docker is used only to *build*.
- **Board roles are build-time:** one firmware build is INITIATOR, one is RESPONDER. Wrist vs ankle is a *label chosen in the app*, not a firmware concern.
- **Accelerometer:** ST LIS2DH12, 3-axis only (no gyro/mag). Sample at **100 Hz**.
- **UWB ranging rate:** ~10–20 Hz.
- **Packet fields:** `seq` (uint16), `board_time_ms` (uint32), `accel_x/y/z` (int16 raw), `uwb_distance_mm` (uint32, initiator only; 0xFFFFFFFF sentinel on responder).
- **Toolchain fallback:** if the community repo blocks us, fall back to official Qorvo QM33 SDK + SEGGER Embedded Studio (native macOS). Note the blocker in the task before switching.
- **Firmware base repo:** https://github.com/Uberi/DWM3001C-starter-firmware
- **Frequent commits.** Each task ends by committing.

---

## Learning primer (read once before starting)

New-to-the-field concepts you'll meet, in plain terms:

- **J-Link / SWD:** The board has a built-in SEGGER "J-Link" debugger chip on the *lower* USB port (J9). SWD (Serial Wire Debug) is the 2-wire protocol it uses to program and debug the nRF52833. This is how firmware gets onto the chip and how you read debug logs.
- **`nrfjprog`:** Nordic's command-line tool that drives J-Link to erase/flash/reset the nRF52833. Your primary flashing command on macOS.
- **`.hex` file:** The compiled firmware image. Building produces one; flashing puts it on the chip.
- **RTT / Virtual COM Port:** Two ways the board sends text logs back to your Mac — SEGGER RTT (over the debug link) or a USB serial port. We'll use whichever the repo defaults to.
- **Two-Way Ranging (TWR):** Two UWB radios bounce timestamped messages; from the round-trip time they compute distance. "Single-Sided" (SS-TWR) is the simplest variant and what the examples use.
- **GATT / characteristic / notify:** BLE's data model. A *peripheral* exposes a *service* containing *characteristics*. A characteristic with *notify* pushes new values to the connected *central* (the phone) without polling. Our sensor packet is a notify characteristic.
- **Central vs peripheral:** The boards are peripherals (they advertise); the phone is the central (it scans and connects). One central can connect to multiple peripherals — that's how the phone talks to both boards.

---

## Milestone 0 — Environment & first light

**Outcome:** Both boards flashed with the stock ranging example, printing a live distance measurement between them. This alone validates the UWB hardware.

### Task 0.1: Host tooling + confirm the Mac sees a board

**Files:**
- Create: `README.md` (project root — running setup log)
- Create: `firmware/` (empty dir; repo goes here next task)

**Interfaces:**
- Produces: a verified macOS toolchain (`nrfjprog`, J-Link) and confirmation that a board enumerates.

- [ ] **Step 1: Unbox and inventory.** Physically confirm you have: 2× DWM3001CDK boards, 2× micro-USB (or USB-C, check) cables, and your powerbank. Identify the **J9 (lower)** USB connector on each board — that's the J-Link/debug port you plug into your Mac. Note the other USB port is the nRF's native USB, not used for flashing.

- [ ] **Step 2: Install Homebrew if absent.**

Run:
```bash
which brew || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
Expected: `brew` path prints, or installer runs to completion.

- [ ] **Step 3: Install SEGGER J-Link tools + Nordic command-line tools.**

Run:
```bash
brew install --cask segger-jlink
brew install --cask nordic-nrf-command-line-tools
```
Expected: both casks install. If a cask name has changed, download directly:
- J-Link: https://www.segger.com/downloads/jlink/ (macOS "J-Link Software and Documentation Pack")
- nRF Command Line Tools: https://www.nordicsemi.com/Products/Development-tools/nRF-Command-Line-Tools

Verify:
```bash
nrfjprog --version
JLinkExe -? 2>/dev/null | head -1
```
Expected: `nrfjprog` prints a version; `JLinkExe` launches (Ctrl-C / `q` to exit).

- [ ] **Step 4: Plug in ONE board via J9 and confirm the Mac sees the J-Link.**

Run:
```bash
nrfjprog --ids
```
Expected: one J-Link serial number prints (a number like `760xxxxxx`). **If empty:** try the other USB port, reseat the cable (some cables are charge-only), and check `ls /dev/tty.usb*` / `/dev/tty.*jlink*`.

- [ ] **Step 5: Read the chip to confirm SWD works.**

Run:
```bash
nrfjprog --memrd 0x10000000 --n 16
```
Expected: 16 bytes of the nRF52833 FICR print (non-error). This proves you can talk to the MCU over SWD — the single most important prerequisite.

- [ ] **Step 6: Record what worked in `README.md`.** Write down the exact cask names/versions that installed, the J-Link serial numbers of each board (label the physical boards #1 and #2 with tape), and which USB port worked. Commit.

```bash
git add README.md firmware/.gitkeep
git commit -m "chore: verified macOS J-Link toolchain, boards enumerate over SWD"
```

---

### Task 0.2: Build the stock firmware in Docker

**Files:**
- Add (submodule or clone): `firmware/DWM3001C-starter-firmware/`

**Interfaces:**
- Produces: a compiled `.hex` firmware image on the host filesystem, ready to flash.

- [ ] **Step 1: Install Docker Desktop** (if absent): https://www.docker.com/products/docker-desktop/ — launch it, confirm `docker run --rm hello-world` succeeds.

- [ ] **Step 2: Clone the firmware base into the repo.**

Run:
```bash
cd /Users/mariusberger/Documents/TrackingSystem/firmware
git clone https://github.com/Uberi/DWM3001C-starter-firmware.git
cd DWM3001C-starter-firmware
```
Expected: repo clones. Skim its `README.md` and `Makefile` to see the exact `make` targets (they may differ slightly from `build`/`flash`/`stream-debug-logs`).

- [ ] **Step 3: Build the default firmware in Docker.**

Run:
```bash
make build
```
Expected: Docker pulls/builds the toolchain image (slow the first time), compiles, and produces a `.hex` (commonly under `build*/` or `Output/`). Find it:
```bash
find . -name '*.hex' -newermt '-10 minutes'
```
Expected: at least one `.hex` path prints. **If `make build` fails:** capture the error, check the repo's README/issues; if it's an Apple-Silicon/Docker-arch issue, add `--platform linux/amd64` per the repo notes. If unresolved, this is the point to invoke the **official SDK fallback** (note it in `README.md`).

- [ ] **Step 4: Commit the pinned firmware base.** Record the exact commit hash of the cloned repo and the produced hex path in the project `README.md`.

```bash
cd /Users/mariusberger/Documents/TrackingSystem
git add README.md firmware/DWM3001C-starter-firmware
git commit -m "build: compile stock DWM3001C starter firmware via Docker"
```

---

### Task 0.3: Flash both boards and see a live distance ("first light")

**Files:**
- Create: `firmware/roles.md` (documents how the repo selects initiator vs responder — a `#define`, a build flag, or two separate example apps).

**Interfaces:**
- Consumes: the `.hex` from Task 0.2 and the verified flashing setup from Task 0.1.
- Produces: two flashed boards, one initiator + one responder, printing distance.

- [ ] **Step 1: Reconnaissance — how does this repo choose initiator vs responder?** Grep the source for the ranging role. Run:
```bash
cd firmware/DWM3001C-starter-firmware
grep -rniE 'initiator|responder|SS_TWR|role' Src include 2>/dev/null | head -40
```
Expected: you find where the role is set (a `#define`, a config value, or two build targets). **Write your finding into `firmware/roles.md`** — this is the fact every later firmware task depends on.

- [ ] **Step 2: Flash board #1 as RESPONDER.** With only board #1 connected via J9, build/flash the responder role per what you found (e.g. set the `#define`, `make build`, then flash the hex from the host):
```bash
nrfjprog -f nrf52 --program <path-to-responder.hex> --chiperase --verify
nrfjprog -f nrf52 --reset
```
Expected: `Programming... Verified OK. Applying reset.` (If the repo's `make flash` uses J-Link and works from host, you may use that instead — but on macOS the direct `nrfjprog` route above is the reliable one.)

- [ ] **Step 3: Flash board #2 as INITIATOR.** Disconnect #1, connect #2, rebuild for the initiator role, flash the same way. Label the physical boards with their roles.

- [ ] **Step 4: Power both and watch the distance.** Connect the INITIATOR to your Mac (for logs), power the RESPONDER from the powerbank, place them ~1 m apart. Open the log stream:
```bash
# whichever the repo uses — try its make target first:
make stream-debug-logs
# fallback (SEGGER RTT):
JLinkRTTLogger -Device NRF52833_XXAA -If SWD -Speed 4000 /dev/stdout
# fallback (serial):
ls /dev/tty.usb* ; screen /dev/tty.usbmodemXXXX 115200
```
Expected: **a distance value prints and changes as you move the boards apart/together.** This is first light — UWB hardware validated.

- [ ] **Step 5: Record results.** In `firmware/roles.md`, note the exact commands that produced logs, the resting distance stability, and the observed range. Commit.
```bash
cd /Users/mariusberger/Documents/TrackingSystem
git add firmware/roles.md README.md
git commit -m "feat: both boards ranging, live distance verified (first light)"
```

**Milestone 0 gate:** You can flash either board and read a live, moving distance. Do not proceed until this is solid — everything else builds on it.

---

## Milestone 1 — Read the accelerometer

**Outcome:** Each board reads its LIS2DH12 at 100 Hz and prints accel values that respond to movement, over the existing log channel.

### Task 1.1: Reconnaissance — locate the LIS2DH12 interface

**Files:**
- Create: `firmware/accel-notes.md`

**Interfaces:**
- Produces: documented bus (SPI or I²C), pins, device address/CS, and any existing driver functions for the LIS2DH12.

- [ ] **Step 1: Search the SDK for the accelerometer.**
```bash
cd firmware/DWM3001C-starter-firmware
grep -rniE 'lis2dh|accel|LIS2|0x18|0x19|WHO_AM_I' . 2>/dev/null | grep -vi build | head -50
```
Expected: you find either an existing driver, or the SPI/I²C pins the module uses. Cross-reference the DWM3001C datasheet for the LIS2DH12 wiring if the SDK is silent.

- [ ] **Step 2: Document findings** in `firmware/accel-notes.md`: bus type, pin numbers, the `WHO_AM_I` register (0x0F, expected value `0x33` for LIS2DH12), the output registers (`OUT_X_L`=0x28 … with auto-increment), and the `CTRL_REG1` (0x20) setting for 100 Hz. Commit.

---

### Task 1.2: Read accel at 100 Hz and print it

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/main.c` (or the app entry the repo uses)
- Create: `firmware/DWM3001C-starter-firmware/Src/accel.c` + `Src/accel.h`

**Interfaces:**
- Consumes: bus/pins from `accel-notes.md`.
- Produces: `void accel_init(void);` and `bool accel_read(int16_t *x, int16_t *y, int16_t *z);` — used by Milestone 2's BLE packing.

- [ ] **Step 1: Write `accel.h`** declaring the two functions above.

- [ ] **Step 2: Implement `accel.c`** — initialize the bus, verify `WHO_AM_I == 0x33`, set `CTRL_REG1 = 0x57` (100 Hz, all axes, normal mode), and read the 6 output bytes into three int16. *(Reconcile the exact SPI/I²C transfer calls with the SDK's HAL found in recon — e.g. Nordic `nrfx_spim_xfer` — rather than a generic stub.)*

- [ ] **Step 3: Call it from the main loop** at ~100 Hz and print `x,y,z` over the log channel, alongside the existing distance print.

- [ ] **Step 4: Flash and verify (hardware "test").** Flash one board, open logs, and **rotate/shake it**: gravity should show ~±16000 raw counts (±2 g range) on whichever axis points down, and values must change with motion. If `WHO_AM_I` mismatches, revisit the bus/pins.

- [ ] **Step 5: Commit.**
```bash
git add firmware/DWM3001C-starter-firmware/Src/accel.* firmware/DWM3001C-starter-firmware/Src/main.c firmware/accel-notes.md
git commit -m "feat: read LIS2DH12 accelerometer at 100Hz, values respond to motion"
```

---

## Milestone 2 — Custom BLE sensor stream

**Outcome:** Each board advertises a BLE service and streams the packet (accel + seq + board_time + distance on initiator) as notifications, verifiable with Nordic's free **nRF Connect** phone app before the iOS app exists.

### Task 2.1: Reconnaissance — the SDK's BLE stack + define the contract

**Files:**
- Create: `firmware/ble-contract.md` (the single source of truth for UUIDs + packet layout, shared with the iOS app)

**Interfaces:**
- Produces: service UUID, characteristic UUID, and the exact byte layout below.

- [ ] **Step 1: Find the BLE example in the SDK.**
```bash
grep -rniE 'ble_|softdevice|gatt|advertis|sd_ble' firmware/DWM3001C-starter-firmware/Src firmware/DWM3001C-starter-firmware/SDK* 2>/dev/null | head -40
```
Expected: locate whether it uses the nRF5 SoftDevice BLE API and any existing service. Document in `ble-contract.md`.

- [ ] **Step 2: Freeze the contract** in `firmware/ble-contract.md`, verbatim, so firmware and iOS agree:
  - Service UUID: `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
  - Sensor characteristic UUID (notify): `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
  - Packet (little-endian, 16 bytes): `seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32` (`uwb_mm = 0xFFFFFFFF` on responder).
  - Advertised name: `DWM-INIT` / `DWM-RESP` so the phone can tell boards apart. Commit.

---

### Task 2.2: Implement the notify characteristic and stream packets

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/main.c`
- Create: `firmware/DWM3001C-starter-firmware/Src/sensor_ble.c` + `.h`

**Interfaces:**
- Consumes: `accel_read()` (Task 1.2), the ranging distance variable (Task 0.3 recon), the contract (Task 2.1).
- Produces: a BLE peripheral emitting the 16-byte packet at the accel rate.

- [ ] **Step 1: Implement `sensor_ble.c`** — register the service + notify characteristic with the contract UUIDs, set the advertised name by role, and expose `void sensor_ble_notify(const uint8_t packet[16]);`. *(Reconcile with the SoftDevice API found in recon — `sd_ble_gatts_*`, `ble_advertising_*`.)*

- [ ] **Step 2: Assemble and send the packet** in the main loop: increment `seq`, read `board_time_ms` from the RTC/millis source, pack accel + latest `uwb_mm` (sentinel on responder) little-endian per the contract, call `sensor_ble_notify()`. Throttle notifications to the 100 Hz accel cadence.

- [ ] **Step 3: Flash INITIATOR, verify with nRF Connect.** Install **nRF Connect for Mobile** (App Store) on your iPhone. Scan → you should see `DWM-INIT`. Connect, find the sensor characteristic, enable notifications: **raw bytes should stream and change as you move the board.** Decode one packet by hand to confirm field order/endianness matches the contract.

- [ ] **Step 4: Flash RESPONDER, verify** it advertises `DWM-RESP` and streams with `uwb_mm = FFFFFFFF`.

- [ ] **Step 5: Commit.**
```bash
git add firmware/DWM3001C-starter-firmware/Src/sensor_ble.* firmware/DWM3001C-starter-firmware/Src/main.c firmware/ble-contract.md
git commit -m "feat: BLE notify stream of accel+distance packets, verified in nRF Connect"
```

**Milestone 2 gate:** Both boards stream decodable packets over BLE, confirmed with a generic BLE app. The firmware is now "done" for Phase 1; remaining work is the iOS app.

---

## Milestone 3 — iOS app (data instrument)

**Outcome:** A Swift app that connects to both boards, shows live data + packet rate, records labeled CSV captures, and exports them. This milestone uses **real test-first development** for the pure-logic pieces (packet decoding, CSV formatting).

### Task 3.1: Xcode project + BLE central skeleton

**Files:**
- Create: `ios/GymTracker.xcodeproj` and `ios/GymTracker/…` (SwiftUI app)
- Create: `ios/GymTracker/BLE/BLEManager.swift`

**Interfaces:**
- Produces: `BLEManager: ObservableObject` with `@Published var boards: [BoardConnection]` where `BoardConnection` has `id`, `name`, `isConnected`, `lastPacket`.

- [ ] **Step 1: Create the app** in Xcode (SwiftUI, iOS 16+). Add `NSBluetoothAlwaysUsageDescription` to Info.plist ("Connects to the tracking boards"). CoreBluetooth requires a **physical iPhone** (the Simulator has no BLE).

- [ ] **Step 2: Implement `BLEManager`** as a `CBCentralManagerDelegate` that scans for the contract **service UUID**, connects to any board found (up to 2), discovers the sensor characteristic, and subscribes to notifications. Publish per-board connection state.

- [ ] **Step 3: Minimal `ContentView`** listing each connected board's name + connection status. Run on your iPhone with both boards powered: **both `DWM-INIT` and `DWM-RESP` should appear as Connected.** Commit.
```bash
git add ios ; git commit -m "feat(ios): BLE central connects to both boards"
```

---

### Task 3.2: Packet decoding (test-first)

**Files:**
- Create: `ios/GymTracker/BLE/SensorPacket.swift`
- Create: `ios/GymTrackerTests/SensorPacketTests.swift`

**Interfaces:**
- Produces: `struct SensorPacket { let seq: UInt16; let boardTimeMs: UInt32; let ax, ay, az: Int16; let uwbMm: UInt32? }` and `init?(_ data: Data)` returning `nil` on wrong length; `uwbMm == nil` when raw == 0xFFFFFFFF.

- [ ] **Step 1: Write the failing test.**
```swift
func test_decodesLittleEndianPacket() {
    // seq=1, time=2, ax=3, ay=-4, az=5, uwb=1000
    var d = Data()
    d.append(contentsOf: [0x01,0x00])                 // seq=1
    d.append(contentsOf: [0x02,0x00,0x00,0x00])       // time=2
    d.append(contentsOf: [0x03,0x00])                 // ax=3
    d.append(contentsOf: [0xFC,0xFF])                 // ay=-4
    d.append(contentsOf: [0x05,0x00])                 // az=5
    d.append(contentsOf: [0xE8,0x03,0x00,0x00])       // uwb=1000
    let p = SensorPacket(d)
    XCTAssertEqual(p?.seq, 1); XCTAssertEqual(p?.boardTimeMs, 2)
    XCTAssertEqual(p?.ax, 3); XCTAssertEqual(p?.ay, -4); XCTAssertEqual(p?.az, 5)
    XCTAssertEqual(p?.uwbMm, 1000)
}
func test_responderSentinelBecomesNil() {
    let d = Data([0,0, 0,0,0,0, 0,0,0,0,0,0, 0xFF,0xFF,0xFF,0xFF])
    XCTAssertNil(SensorPacket(d)?.uwbMm)
}
func test_wrongLengthReturnsNil() {
    XCTAssertNil(SensorPacket(Data([0,1,2])))
}
```

- [ ] **Step 2: Run tests, verify they fail** (`SensorPacket` undefined). `⌘U` in Xcode.

- [ ] **Step 3: Implement `SensorPacket`** with a 16-byte guard and little-endian reads (`withUnsafeBytes` / `loadUnaligned`), mapping `0xFFFFFFFF` → `nil`.

- [ ] **Step 4: Run tests, verify green.** Wire `BLEManager` to decode incoming `Data` into `SensorPacket`. Commit.
```bash
git add ios ; git commit -m "feat(ios): decode sensor packets with tests"
```

---

### Task 3.3: Live view — accel, distance, packet rate

**Files:**
- Modify: `ios/GymTracker/ContentView.swift`
- Create: `ios/GymTracker/BLE/BoardConnection.swift` (add rate tracking)

**Interfaces:**
- Consumes: `SensorPacket`, `BLEManager`.
- Produces: per-board `packetsPerSecond: Double` and `lossPercent: Double` (from `seq` gaps).

- [ ] **Step 1: Track rate & loss** in `BoardConnection`: maintain a 1-second rolling count for `packetsPerSecond`, and compute `lossPercent` from missing `seq` numbers over a window.

- [ ] **Step 2: Build the live UI** — per board: name, connection dot, live `ax/ay/az` (numbers or a simple `Swift Charts` line), current `uwbMm` (from the initiator), `packetsPerSecond`, `lossPercent`.

- [ ] **Step 3: Verify on device.** Move a board: accel updates smoothly; separate the boards: distance tracks; note the resting `packetsPerSecond` (should be ~100) and `lossPercent`. **Write the observed jitter/loss into `README.md` — this is a Phase 1 deliverable.** Commit.
```bash
git add ios README.md ; git commit -m "feat(ios): live accel/distance view with packet-rate + loss metrics"
```

---

### Task 3.4: Record captures to CSV (test-first for the writer)

**Files:**
- Create: `ios/GymTracker/Recording/CaptureWriter.swift`
- Create: `ios/GymTrackerTests/CaptureWriterTests.swift`
- Modify: `ios/GymTracker/ContentView.swift` (record controls + label fields)

**Interfaces:**
- Produces: `CaptureWriter` with `func header() -> String` and `func row(board: String, phoneArrivalMs: Int64, _ p: SensorPacket) -> String`.
- CSV columns (frozen): `board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm`.

- [ ] **Step 1: Write the failing test.**
```swift
func test_headerColumns() {
    XCTAssertEqual(CaptureWriter().header(),
      "board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm")
}
func test_rowFormatting() {
    let d = Data([0x01,0x00, 0x02,0,0,0, 0x03,0, 0xFC,0xFF, 0x05,0, 0xE8,0x03,0,0])
    let p = SensorPacket(d)!
    let row = CaptureWriter().row(board: "INIT", phoneArrivalMs: 999, p)
    XCTAssertEqual(row, "INIT,1,2,999,3,-4,5,1000")
}
func test_responderRowLeavesUwbBlank() {
    let d = Data([0,0,0,0,0,0,0,0,0,0,0,0,0xFF,0xFF,0xFF,0xFF])
    let p = SensorPacket(d)!
    XCTAssertEqual(CaptureWriter().row(board: "RESP", phoneArrivalMs: 5, p),
                   "RESP,0,0,5,0,0,0,")
}
```

- [ ] **Step 2: Run tests, verify they fail.**

- [ ] **Step 3: Implement `CaptureWriter`** — `header()` returns the frozen columns; `row(...)` formats fields, emitting an empty string for `nil` `uwbMm`.

- [ ] **Step 4: Run tests, verify green.**

- [ ] **Step 5: Wire recording UI** — an exercise-name text field, a wrist/ankle picker mapping each board to a limb (stored in the filename/metadata), and Start/Stop. On Start, open a file `capture_<exercise>_<timestamp>.csv` in the app's Documents dir, write `header()`, then append `row(...)` per packet using the phone arrival time (`Date().timeIntervalSince1970 * 1000`). On Stop, close the file.

- [ ] **Step 6: Verify** a short recording produces a well-formed CSV (check via Xcode's device container or the Files app). Commit.
```bash
git add ios ; git commit -m "feat(ios): record labeled captures to CSV with tests"
```

---

### Task 3.5: Export captures

**Files:**
- Modify: `ios/GymTracker/ContentView.swift`

**Interfaces:**
- Produces: a share action exposing recorded CSVs.

- [ ] **Step 1: Add a captures list** reading the Documents dir, each row a capture with a share button.

- [ ] **Step 2: Present a `UIActivityViewController`** (via `ShareLink` or a `UIViewControllerRepresentable`) for the selected CSV so you can AirDrop/save to Files.

- [ ] **Step 3: Verify** you can AirDrop a capture to your Mac and open it in a spreadsheet. Commit.
```bash
git add ios ; git commit -m "feat(ios): export captures via share sheet"
```

---

## Milestone 4 — Validation captures

**Outcome:** Real captures inspected on the laptop, answering the Phase 1 questions from the spec.

### Task 4.1: Bench + worn validation and write-up

**Files:**
- Create: `docs/phase1-findings.md`

- [ ] **Step 1: Bench checks.** Record short captures while: (a) holding a board still on each face — confirm gravity lands ~±1 g on the expected axis; (b) sliding the boards apart on a table — confirm `uwb_mm` grows roughly linearly with real distance (tape-measure a few points).

- [ ] **Step 2: Worn captures.** Wrist + ankle, powerbank-powered, record a few reps each of ~4 distinct exercises (e.g. squat, deadlift, biceps curl, push-up). One capture per exercise, correctly labeled.

- [ ] **Step 3: Inspect on laptop.** Plot the CSVs (any tool — Python/Numbers). For each exercise, eyeball whether the accel traces + the wrist↔ankle distance curve look **distinguishable**.

- [ ] **Step 4: Write `docs/phase1-findings.md`** answering the spec's four questions explicitly: (1) accel cleanliness/resolution, (2) UWB distance usefulness/stability, (3) BLE jitter/loss + cross-board clock drift (compare `board_time_ms` vs `phone_arrival_ms` across the two streams), (4) are exercise signatures visible by eye. Add a short **"production hardware" recommendation** section (e.g. does the lack of a gyro block bar-path badly enough to justify a 6/9-axis IMU). Commit.
```bash
git add docs/phase1-findings.md ; git commit -m "docs: Phase 1 validation findings and production hardware recommendations"
```

**Phase 1 gate / definition of done:** You have labeled CSV captures of multiple exercises, a written findings doc answering all four spec questions, and a clear read on whether this hardware is sufficient or what to change — the input to deciding Phase 2.

---

## Self-review notes (coverage vs spec)

- Spec "3-axis accel + UWB distance streaming" → Milestones 1, 2. ✅
- Spec "two independent BLE peripherals, initiator/responder" → Task 0.3, 2.2, Global Constraints. ✅
- Spec "iOS app: connect both, live view, record CSV, export, packet rate/loss" → Tasks 3.1–3.5. ✅
- Spec "dual timestamps to measure jitter/drift" → packet `board_time_ms` + CSV `phone_arrival_ms`, analyzed in Task 4.1 Step 4. ✅
- Spec "answer the four validation questions" → Task 4.1. ✅
- Spec non-goals (classification, fusion, review UI, ML) → intentionally absent. ✅
- Note: firmware code is grounded in reconnaissance steps rather than fabricated SDK calls, because the exact Qorvo API is discovered on first contact with the SDK. This is deliberate, not a placeholder.
