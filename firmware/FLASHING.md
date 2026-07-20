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

## 4b. Stock examples ALSO need the SoftDevice — use §4a

**There is no app-only path in this repo.** Since S112 was added to the emProject
(commit `897d257`), *every* build — including the stock Qorvo examples — links
above the SoftDevice. The app starts at **0x19000**; the chip boots from **0x0**.
Flash the app alone and 0x0 is erased, so nothing runs.

The failure is silent and convincing: `Program & Verify` reports `O.K.` because
the bytes really were written. The board is simply dead. Diagnose it by reading
the RTT control block address from the `.map` and dumping that memory — random
garbage means `.bss` was never zeroed, i.e. the firmware never started:

```bash
grep -n "_SEGGER_RTT" DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.map
# then: JLinkExe ... mem <addr> 0x30   -> expect "SEGGER RTT" ASCII, not noise
```

Use the §4a two-file command for everything.

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

**Always resume afterwards — `pkill` leaves the core halted:**

```bash
JLinkExe -CommanderScript /dev/stdin >/dev/null 2>&1 <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
g
q
EOF
```

Two traps here, both of which cost time on 2026-07-19:

1. **Attaching to an already-running target usually yields zero lines.** Reset
   (`r`,`g`) in a *separate* `JLinkExe` call first, then attach — and keep the
   logger attached for the whole window rather than reattaching.
2. **`pkill`-ing the logger halts the CPU.** The board stops advertising and
   looks bricked; it is just paused. Resume with the `g` block above. A reset
   also works but reboots the app and drops any BLE connection.

Also: a read taken without a reset can show **ghost output from a previous
boot**. Never diagnose from RTT lines unless you reset immediately before.

## 7. Stashed images — `firmware/hex/`

| File | What |
|---|---|
| `s112_softdevice.hex` | SoftDevice, always flashed first with our firmware |
| `sensor_stream_init.hex` | M2a.2 verified initiator (accel only, `uwb_mm` sentinel) |
| `m2b1_resp_probe.hex` | M2b.1 Task 1 responder + deadline-margin probe |
| `initiator.hex` / `responder.hex` | M0 stock SS-TWR pair |
| `accel_test.hex`, `ble_test.hex` | M1 / M2a.1 |
