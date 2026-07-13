# TrackingSystem

Gym exercise tracking system built on two Qorvo DWM3001CDK dev kits (UWB +
3-axis accelerometer), streaming to an iOS app. See `docs/superpowers/specs/`
for the design and `docs/superpowers/plans/` for the implementation plan.

## Setup log (Phase 1)

### Host environment (macOS, Apple Silicon / arm64)
- Homebrew, git, Xcode 16.4 — pre-existing.
- `segger-jlink` 9.58 and `nordic-nrf-command-line-tools` 10.24.2 — installed via
  Homebrew cask. **The `.pkg` install needs a real terminal for the sudo
  password** — run `brew install --cask ...` in Terminal.app, not via a
  non-interactive shell.
- Docker Desktop — for the firmware build (Task 0.2). Not yet installed.

### Boards
- Two DWM3001CDK boards. **Flash/debug via the J9 (lower) micro-USB port** — the
  onboard SEGGER J-Link. The J20 (upper) port is the nRF52833's native USB and
  shows nothing on an unprogrammed board.
- Board #1 J-Link serial: **760224825**.

### Cable gotcha (cost us real time — read this)
- The board's J9 port is **standard Micro-USB 2.0 (Micro-B)** — NOT the wide
  USB 3.0 Micro-B used on external hard drives.
- **Charge-only cables light the board LED but carry no data**, so the J-Link
  never enumerates. Symptom: LED on, but `nrfjprog --ids` / `system_profiler`
  show no J-Link. We burned two charge-only cables before finding a data one.
  **Keep the known-good data cable labelled.**
- Quick check that a cable + board are alive:
  `system_profiler SPUSBDataType | grep -i segger` should show `J-Link`, and
  `ls /dev/cu.usbmodem*` should list a port.

### SWD verified
- `JLinkExe` connects cleanly: identifies Cortex-M4, reads FICR DEVICEID. Full
  SWD control confirmed. Task 0.1 gate passed.
- **Known issue:** `nrfjprog` prints `JLinkARM.dll error -256` spam (J-Link
  V9.58 vs nrfjprog version mismatch). It still returns correct data, but if
  flashing misbehaves, either align the J-Link version or flash via `JLinkExe`
  (`loadfile <fw>.hex`) as the fallback.

### Milestone 0 complete — first light (UWB ranging)
- Board #1 (J-Link serial **760224825**) → SS-TWR **initiator**.
- Board #2 (J-Link serial **760224846**) → SS-TWR **responder**.
- Flashed from host with `JLinkExe loadfile` (see `firmware/roles.md`); prebuilt
  images in `firmware/hex/{initiator,responder}.hex`.
- Live ranging confirmed via initiator RTT: steady `DIST: ~0.73 m` with ~±5 cm
  jitter at rest. UWB hardware validated.

RTT log capture (a few seconds, then Ctrl-C / kill):
```bash
JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 out.log
```

Direct J-Link sanity check (no nrfjprog):
```bash
cat > /tmp/probe.jlink <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
mem32 0x10000060 2
exit
EOF
JLinkExe -CommanderScript /tmp/probe.jlink -AutoConnect 1
```
