# M2a.2 — Accelerometer-over-BLE stream (design)

**Date:** 2026-07-18
**Status:** approved, ready for implementation plan
**Milestone:** M2a.2 (see `docs/architecture.md` §6 roadmap)
**Depends on:** M1 accelerometer (`accel_init`/`accel_read`), M2a.1 BLE advertising
(verified — tag advertises as `DWM-SENSOR`), S112 SoftDevice up.

## 1. Goal

Make a tag **stream its accelerometer readings to the phone over BLE**, not just
advertise. Success = raw 16-byte packets stream over a custom GATT notify
characteristic and are visible/changing in nRF Connect when the tag is moved.

This is the first of the two-step BLE build (ADR-2): **accelerometer only** now,
with the distance field set to the "none" sentinel. Live UWB distance
(concurrent UWB + BLE radio coexistence) is deferred to **M2b** and is explicitly
**out of scope** here.

## 2. Architecture context

Unchanged from `docs/architecture.md`: the tag is a dumb data provider (BLE
peripheral) that streams only its own data; the phone is the brain. This spec
covers only the tag-firmware side of that contract.

## 3. Wire contract (frozen)

Created here as the shared source of truth: `firmware/ble-contract.md`.

- **Service UUID:** `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
- **Sensor characteristic (notify):** `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
- **Packet — 16 bytes, little-endian:**

  | offset | field          | type   | notes |
  |--------|----------------|--------|-------|
  | 0      | `seq`          | uint16 | increments per packet; wraps at 65535 |
  | 2      | `board_time_ms`| uint32 | monotonic ms since boot |
  | 6      | `ax`           | int16  | raw left-justified LIS2DH12 X |
  | 8      | `ay`           | int16  | raw left-justified LIS2DH12 Y |
  | 10     | `az`           | int16  | raw left-justified LIS2DH12 Z |
  | 12     | `uwb_mm`       | uint32 | distance in mm; `0xFFFFFFFF` = none |

- In M2a.2 `uwb_mm` is **always** `0xFFFFFFFF`.
- Must match the iOS decoder `ios/SensorCore/Sources/SensorCore/SensorPacket.swift`
  (already unit-tested against this layout).

## 4. Module: `sensor_ble.c` / `sensor_ble.h`

Grown from the working `ble_test.c`. Encapsulates all SoftDevice/GATT detail
behind a two-function interface so `main.c` never touches `sd_*` calls.

```c
/* Bring up SoftDevice + advertising (as M2a.1) AND register the custom GATT
 * service + notify characteristic from the contract. Advertises by role name
 * (DWM-INIT / DWM-RESP). Returns false on any init error. */
bool sensor_ble_init(void);

/* Push one 16-byte packet to the subscribed central. No-op if no central is
 * connected or notifications are not enabled. Never blocks. */
void sensor_ble_notify(const uint8_t packet[16]);
```

Internally `sensor_ble.c` owns: the service/characteristic registration
(`sd_ble_gatts_service_add`, `sd_ble_gatts_characteristic_add` with the 128-bit
vendor-specific UUID), the advertising setup (reusing the M2a.1 path), the
connection-handle bookkeeping, and the BLE event handler.

**Role selection:** a compile-time `#define` (e.g. `SENSOR_ROLE_INITIATOR`)
chooses the advertised name `DWM-INIT` vs `DWM-RESP`. M2a.2 brings up one tag as
`DWM-INIT`; both roles send the sentinel distance for now.

## 5. Packet assembly & timing (in `main.c` / a `sensor_stream()` entry)

- **Time source:** `board_time_ms` from `app_timer_cnt_get()` (RTC1, already
  running) converted to ms. Monotonic, cheap, no busy-wait.
- **Cadence:** a repeating `app_timer` fires every 10 ms (100 Hz) and sets a
  `sample_due` flag. The main loop sleeps in `sd_app_evt_wait()`; on wake, if
  `sample_due`, it clears the flag, calls `accel_read()`, assembles the packet
  (`seq++`, time, `ax/ay/az`, `uwb_mm = 0xFFFFFFFF`, little-endian), and calls
  `sensor_ble_notify()`.
- **Why sleep, not `nrf_delay_ms`:** busy-waiting starves the SoftDevice; the tag
  must sleep between samples so the radio runs.

## 6. Known limitation (accepted for M2a.2)

BLE throughput is bounded by the **connection interval** (currently 20–75 ms from
the M2a.1 GAP params), not the 100 Hz sample rate. The SoftDevice queues a small
number of notifications per connection event; sustained 100 Hz may not fully get
through until the connection interval is tuned. **This is acceptable here** —
M2a.2's bar is "bytes stream and change," and exact rate/loss is measured on the
phone in M3 (and tuned then if needed). If `sd_ble_gatts_hvx` returns
`NRF_ERROR_RESOURCES`, `sensor_ble_notify` drops that packet silently (the `seq`
gap is the phone's loss signal).

## 7. Files

- **Create:** `firmware/DWM3001C-starter-firmware/Src/sensor_ble.c` + `.h`
- **Create:** `firmware/ble-contract.md`
- **Modify:** `firmware/DWM3001C-starter-firmware/Src/main.c` — add a
  `sensor_stream()` entry in the existing example-dispatch pattern; dispatch to it.
- **Modify:** `Src/example_selection.h` if a `TEST_*`-style toggle is used for the
  entry (follow existing pattern).
- Note: `ble_test.c` stays as the M2a.1 reference; `sensor_ble` supersedes it for
  the stream. (Only one example entry is active in `main.c` at a time.)

## 8. Verification (manual, on hardware)

1. Build clean (`make clean && make build` — remember the stale-object hazard),
   flash S112 + app to a board.
2. RTT shows init steps returning `0x0` and "streaming as DWM-INIT".
3. nRF Connect → scan → see `DWM-INIT` → connect → discover service
   `6E40FE00…` → enable notifications on `6E40FE01…`.
4. **Bytes stream and the accel fields change as the board is tilted/moved.**
5. Hand-decode one packet: confirm `seq` increments, `board_time_ms` advances,
   `ax/ay/az` are plausible (~±256 counts ≈ 1 g on the down axis after `>>6`),
   `uwb_mm` = `FF FF FF FF`. Field order/endianness must match the contract.

## 9. Out of scope (later milestones)

- Live UWB distance in the stream (**M2b**): concurrent UWB ranging + BLE.
- Two-board simultaneous bring-up / runtime role selection (**M2b/M3**).
- Connection-interval / throughput tuning and rate/loss measurement (**M3**).
- iOS app consumption (**M3**).

## 10. Testing note

This is embedded firmware with hardware/radio side effects; there is no
host-runnable unit test for the notify path. Verification is the manual nRF
Connect procedure in §8. The one pure-logic piece — packet byte layout — is
already covered by the iOS `SensorPacketTests`, and the firmware packing must
match it (verified by hand-decode in §8 step 5).
