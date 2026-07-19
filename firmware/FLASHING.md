# Flashing cheatsheet

All commands run from `firmware/`. Docker Desktop must be running for builds.
Only the labelled **data** USB cable works, in the **J9 lower port**.

---

## 1. Choose the role — `DWM3001C-starter-firmware/Src/example_selection.h`

| Target | Lines |
|---|---|
| Our firmware, initiator | `#define TEST_SENSOR_STREAM` + `#define SENSOR_ROLE_INITIATOR` |
| Our firmware, responder | `#define TEST_SENSOR_STREAM` + `//#define SENSOR_ROLE_INITIATOR` |
| Stock UWB poll source | `//#define TEST_SENSOR_STREAM` + `#define TEST_SS_TWR_INITIATOR` |

## 2. Build

```bash
cd DWM3001C-starter-firmware
DOCKER_DEFAULT_PLATFORM=linux/amd64 make clean
DOCKER_DEFAULT_PLATFORM=linux/amd64 make build
cd ..
```

`make clean` is mandatory whenever the emProject or its defines changed — a stale
object caused the M2a.1 HardFault.

## 3. Confirm the build is what you think it is

```bash
strings DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.elf | grep -E '^DWM-(INIT|RESP)$'
```

Build output is thousands of lines of noise; check this and the hex timestamp,
not the log tail.

## 4a. Flash our firmware — SoftDevice **first**, then app

```bash
JLinkExe -CommanderScript /dev/stdin <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
erase
loadfile hex/s112_softdevice.hex
loadfile DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex
r
g
q
EOF
```

Expect **two** `Program & Verify` `O.K.` lines. Flashing the app alone leaves the
board silent — it needs the SoftDevice.

## 4b. Flash a stock example — app only, no SoftDevice

```bash
JLinkExe -CommanderScript /dev/stdin <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
erase
loadfile DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex
r
g
q
EOF
```

## 5. Pick a specific board (when both are connected)

Add `-SelectEmuBySN <serial>` right after `JLinkExe`. List what's attached:

```bash
system_profiler SPUSBDataType | grep -A6 "J-Link"
```

Known serials: `760224825`, `760224846`. Which is physically "#1" vs "#2" is
**not** established — label them before trusting a number.

## 6. Read RTT output

```bash
JLinkExe -CommanderScript /dev/stdin >/dev/null 2>&1 <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
r
g
q
EOF
sleep 2
(JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 /tmp/rtt.log >/dev/null 2>&1 &)
sleep 8
pkill -f JLinkRTTLogger
strings /tmp/rtt.log
```

The reset-then-log step matters: without it you often get
`RTT Control Block not found`, and a stale read can show ghost output from the
previous image.

## 7. Stashed images — `firmware/hex/`

| File | What |
|---|---|
| `s112_softdevice.hex` | SoftDevice, always flashed first with our firmware |
| `sensor_stream_init.hex` | M2a.2 verified initiator (accel only, `uwb_mm` sentinel) |
| `m2b1_resp_probe.hex` | M2b.1 Task 1 responder + deadline-margin probe |
| `initiator.hex` / `responder.hex` | M0 stock SS-TWR pair |
| `accel_test.hex`, `ble_test.hex` | M1 / M2a.1 |
