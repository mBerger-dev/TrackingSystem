# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A gym-exercise tracking system: two Qorvo **DWM3001CDK** tags (UWB ranging + LIS2DH12
accelerometer) stream sensor data over BLE to an **iOS app**. The tags are dumb data
providers; the phone is the brain. This is Phase 1 — the sensor-streaming foundation.

The repo has three parts:

- `firmware/` — nRF52833 firmware for the tags, built on the Qorvo DWM3001C starter
  firmware (a heavily-modified vendor SDK). Custom code lives in
  `firmware/DWM3001C-starter-firmware/Src/{accel,uwb,ble}/`.
- `ios/` — the phone side: a testable Swift package (`SensorCore`) plus the app (`TrackingApp`).
- `docs/` — `architecture.md` is a **living ADR document** (see below); specs and plans
  live under `docs/superpowers/{specs,plans}/`.

## Commands

**iOS logic tests (no hardware, run these often):**
```bash
cd ios/SensorCore && swift test
```
`SensorCore` is pure Foundation — the loss-measurement logic (`LinkStats`) is deliberately
kept free of CoreBluetooth so it can be verified against synthetic input on a Mac.

**Verify the app compiles (no device, no signing):**
```bash
cd ios && xcodebuild -workspace TrackingSystem.xcworkspace -scheme TrackingApp \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Xcode's SourceKit frequently reports bogus `No such module 'SensorCore'` errors — trust
this command over the editor's live diagnostics. Always open the **workspace**, never the
`.xcodeproj`.

**Firmware build (Docker):**
```bash
cd firmware/DWM3001C-starter-firmware
make build      # runs emBuild inside the uberi/qorvo-nrf52833-board image
make clean      # REQUIRED after changing emProject-level preprocessor defines (see gotchas)
```
The Docker image is amd64; on Apple Silicon it runs under emulation (force `linux/amd64`
if the platform isn't picked up). `dw3000_api.emProject` must be **hand-edited** for any
file add/remove/rename — there is no auto-discovery.

**Flashing:** the Makefile's `flash`/RTT targets assume a Linux host. On the macOS dev host,
flash from the host instead with J-Link directly (`JLinkExe` → `loadfile <fw>.hex`); prebuilt
images are in `firmware/hex/`. See `firmware/FLASHING.md` and `firmware/roles.md`.

## Architecture

**Data flow (one direction):** each tag samples at **100 Hz**, packs a fixed **16-byte packet**,
and pushes it as a BLE GATT **notify**. The phone subscribes, decodes, and computes link
statistics. Nothing is sent back to the tags.

**The wire contract is frozen and shared.** `firmware/ble-contract.md` is the single source of
truth for the GATT UUIDs and the 16-byte packet layout. It is implemented on both sides —
`Src/ble/sensor_ble.c` (firmware) and `ios/SensorCore/Sources/SensorCore/SensorPacket.swift`
(phone). **Never change one side without the other**, and treat the byte layout as fixed:
firmware-side decisions (e.g. NLOS rejection) are expressed as the `uwb_mm = 0xFFFFFFFF`
sentinel rather than by widening the packet. Tags are told apart by advertised name:
`DWM-INIT` (reports real distance) vs `DWM-RESP` (always sends the distance sentinel).

**Firmware layering** (`Src/`): `accel/` is the LIS2DH12 I2C driver; `uwb/ranging.c` is the
IRQ-driven SS-TWR exchange; `ble/sensor_ble.c` owns the GATT service and `ble/sensor_stream.c`
is the 100 Hz sampler that assembles and sends packets. BLE requires the Nordic **S112
SoftDevice** — a deploy is two hex files (SoftDevice **and** app), not just the app.

**iOS module boundary is intentional.** `SensorCore/` (Swift package, builds/tests on macOS)
holds `SensorPacket` (decode), `LinkStats` (packet rate + loss from seq numbers, no radio),
and `CaptureWriter` (CSV, unused until recording lands). `TrackingApp/` (device only) holds
the CoreBluetooth adapter (`BoardLink`, one per board), the observable state (`BoardModel`,
which publishes to SwiftUI at 10 Hz to keep the UI from becoming the bottleneck it measures),
and the views. Keep hardware-facing code out of `SensorCore` so it stays Mac-testable.

**Decisions live in `docs/architecture.md`.** It is a living document: §6 is the roadmap and
sequencing, §7 is the decision log (ADRs), §9 tracks known robustness debt. Update it when a
system-level decision lands — do not leave it stale.

## Gotchas that have cost real time

- **`make clean` after emProject preprocessor changes.** emBuild's incremental build does not
  recompile a `.c` when only project-level `#define`s change, leaving stale `.o` files. This
  caused a SoftDevice HardFault that looked like a code bug but was a stale object.
- **BLE redeploy must flash SoftDevice + app.** Flashing only the app leaves the board unable
  to advertise. Flash `s112_softdevice.hex` first, then the app, with absolute paths.
- **Only data USB cables work.** Charge-only Micro-USB cables light the board LED but never
  enumerate the J-Link (no `/dev/cu.usbmodem*`, nothing in `system_profiler | grep -i segger`).
  Flash/debug via the **J9 (lower)** port. Keep the known-good data cable labelled.
- **`nrfjprog` prints `JLinkARM.dll error -256` noise** (J-Link vs nrfjprog version mismatch).
  It still returns correct data; if flashing misbehaves, fall back to `JLinkExe loadfile`.
- **Two boards, J-Link serials 760224825 and 760224846** — which physical board is "#1" vs "#2"
  is **not established** (they're unlabelled). Don't assert a board number from a serial.
- **iOS uses free provisioning → builds stop launching after 7 days.** Re-deploy from Xcode
  before any measurement session; a stale build refusing to open is expected, not a bug.
- **There is no `Info.plist`** (`GENERATE_INFOPLIST_FILE = YES`). The Bluetooth permission
  string lives in build settings as `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`.
- **CoreBluetooth does nothing in the Simulator** — every device-level check needs a real iPhone.
