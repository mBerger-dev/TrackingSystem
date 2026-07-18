# M2 BLE bring-up — debug handoff (resume here)

**Status (2026-07-18):** Milestone 2a.1 (get the board advertising over BLE) is
**blocked** on a firmware boot fault. This doc captures the full investigation so
a fresh session can continue without re-deriving it.

## Pipeline status
- M0 UWB ranging ✅ verified
- M1 Accelerometer ✅ verified
- **M2a.1 BLE advertising 🔴 blocked (this doc)**
- M2a.2 GATT stream, M2b ranging-in-stream ⬜
- M3 iOS app — core logic tested; BLE/UI ⬜
- M4 validation ⬜

## The bug (precise)
The first SoftDevice call, `sd_softdevice_enable()`, executes `svc 16` which
**forced-HardFaults**. RTT shows the app runs up to the SoftDevice enable, then
dies:
```
BLE: ble_test start
  VTOR = 0x0
  app_timer_init -> 0x0
BLE: stack_init...          <- never returns from nrf_sdh_enable_request()
```
Debugger evidence while hung:
- `IPSR = 003 (HardFault)`, `HFSR = 0x40000000` (FORCED), `CFSR = 0`.
- Stacked faulting PC = `0x00022E7C`, which disassembles to:
  `00022e7a <sd_softdevice_enable>: svc 16`.
- A forced HardFault on an `svc` in thread mode = the SVCall exception could not
  be taken / was not routed to the SoftDevice handler.

## Hypotheses tested and REJECTED (do not retry blind)
1. **LF clock = external crystal hang** — switched `NRF_SDH_CLOCK_LF_SRC` 1→0
   (RC osc). No change. (Left at RC=0 in the working tree.)
2. **Interrupts masked (PRIMASK)** — printed `PRIMASK before = 0` (not masked);
   added `__enable_irq()`. No change.
3. **VTOR wrong** — set `SCB->VTOR = 0x19000` manually. No change.
4. **`NO_VTOR_CONFIG` removed during bring-up** — restored it (matches Nordic's
   reference). No change. (Left restored in the working tree.)

## Key reframing (important)
Comparing against Nordic's **working** S112 example
(`.../ble_app_template/pca10040e/s112/ses/...emProject` inside the Docker SDK)
shows our project already matches the known-good config:
- Same startup files: `ses_startup_nrf52833.s`, `ses_startup_nrf_common.s`,
  `system_nrf52833.c`, `thumb_crt0.s`.
- Same app flash base: **`FLASH_START = 0x19000`** (authoritative S112 APP_CODE_BASE).
- `NO_VTOR_CONFIG` now defined (same).

**Conclusion:** the foundation is NOT fundamentally wrong. The fault almost
certainly comes from something in the hand-modifications made while bolting BLE
onto the DW3000 project (sdk_config edits, added linker sections, the DW3000
init running first in `main()`, the `--whole-archive` UWB lib, RAM_START value),
NOT from the startup/boot architecture.

## NEXT STEP (agreed plan)
Build a **minimal clean S112 / nRF52833 app that only advertises** — no DW3000,
no accel, none of the current modifications — flash S112 + it, and check nRF
Connect for `DWM-SENSOR`.
- **If it advertises** → SoftDevice is fine on this board+toolchain; reintroduce
  the DW3000 pieces one at a time until it breaks to pinpoint the culprit.
- **If it also faults** → board/SoftDevice-level issue; investigate there.

Suggested source of the clean base: adapt Nordic's `ble_app_template`
`pca10040e/s112` SES project to `NRF52833_XXAA` + `S112` (it already boots
correctly), OR build a stripped SES project using our confirmed-correct startup
files with only `ble_test.c`'s advertising code.

## Reference facts / how to work the hardware
- Boards (J-Link serials): **#1 = 760224825**, **#2 = 760224846**. Board #2 is
  currently flashed with the broken BLE build.
- **Flash from macOS host** (Docker can't pass USB). SoftDevice must be present
  under the app:
  ```bash
  # both images (erase first):
  JLinkExe -CommanderScript <script>  # erase; loadfile hex/s112_softdevice.hex; loadfile hex/<app>.hex; r; g
  ```
  Stashed images: `firmware/hex/s112_softdevice.hex`, `firmware/hex/ble_test.hex`,
  plus `initiator.hex`, `responder.hex`, `accel_test.hex` (pre-BLE roles).
- **Build:** `cd firmware/DWM3001C-starter-firmware && DOCKER_DEFAULT_PLATFORM=linux/amd64 make build`
  → `Output/Common/Exe/dw3000_api.hex`. Docker Desktop must be running.
- **Read RTT logs** (over J-Link):
  ```bash
  JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 out.log
  ```
- **STALE-RAM GOTCHA:** a chip erase does NOT clear RAM. After reflashing, the
  RTT logger can latch onto a leftover control block from the previous firmware
  and show ghost output. **Power-cycle the board (unplug/replug USB) to clear
  RAM** before trusting an RTT read.
- Only **data** USB cables work (the labelled one). Flash/debug via **J9 (lower
  port)**.

## Working-tree state at handoff (uncommitted debug WIP)
Modified since commit `897d257`:
- `Src/ble/ble_test.c` — added step-by-step debug prints (VTOR, PRIMASK earlier,
  per-init-step result codes).
- `Src/sdk_config.h` — `NRF_SDH_CLOCK_LF_SRC` set to 0 (RC osc); RC CTIV/accuracy.
- `dw3000_api.emProject` — `NO_VTOR_CONFIG` restored.
- `firmware/hex/ble_test.hex` — current (broken) build.

See also `firmware/ble-notes.md` (SoftDevice integration details) and the design
spec/plan under `docs/superpowers/`.
