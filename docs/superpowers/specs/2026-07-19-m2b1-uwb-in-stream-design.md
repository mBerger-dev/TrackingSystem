# M2b.1 — Live UWB distance in the sensor stream (design)

**Date:** 2026-07-19
**Status:** approved, ready for implementation plan
**Milestone:** M2b.1 (see `docs/architecture.md` §6 roadmap)
**Depends on:** M2a.2 verified (accel streams over BLE, both roles), M0 UWB ranging
**Diagrams:** `docs/architecture.drawio` — page 2 (priorities), page 4 (interrupt
path and latency budget). Not redrawn here.

## 1. Goal

The initiator fills `uwb_mm` with **real** tag-to-tag distance at 20 Hz instead of
the sentinel. Both tags keep streaming accelerometer data at 100 Hz.

Success = in nRF Connect, with the phone connected to both tags, the initiator's
`uwb_mm` tracks a tape-measured distance while accel keeps streaming on both.

## 2. Scope split (ADR-4)

Reaching usable distance takes two steps, for the same reason ADR-2 split M2a:

- **M2b.1 (this spec)** — prove the mechanism. Line-of-sight only. No signal
  quality logic.
- **M2b.2 (deferred)** — non-line-of-sight rejection. The human body blocks 6.5 GHz
  substantially; a blocked direct path with a surviving reflection produces an
  exchange that **succeeds but reports too long a distance**. The DW3000 exposes
  `dwt_nlos_ipdiag()` for this (worked example: `Src/examples/ex_02a_simple_rx/
  simple_rx_nlos.c:312-330`). The rejection threshold will be set from a measured
  body-blocked run, not from the example's generic 3.3 dB / 6 dB figures, which
  are not calibrated for worn antennas across a torso.

Rationale for the order: a guessed threshold fails invisibly — over-rejection is
indistinguishable from blockage itself. Proving the pipeline first gives a known-good
baseline to measure against.

## 3. Wire contract — unchanged

`firmware/ble-contract.md` stands. 16 bytes, no iOS decoder change.

`uwb_mm` semantics on the initiator:

- **Real value** only in the packet carrying a just-completed successful exchange.
- **`0xFFFFFFFF`** in every other packet — between exchanges, on timeout, and on a
  reading that fails the sanity check below.
- Responder: always `0xFFFFFFFF`.

The phone therefore sees only genuine measurements, each honestly timestamped by
the `board_time_ms` of the packet carrying it. Holding a stale value was rejected:
it makes a 2 s-old reading indistinguishable from a 5 ms-old one.

**Sanity check.** Reject distances that are negative or exceed 50 m, and report
failure rather than a fabricated number. Capping below 50 m also guarantees a real
reading can never collide with the sentinel.

Note this guard does **not** catch NLOS bias, which is centimetres to a couple of
metres and lands inside the plausible band. That is M2b.2's job.

## 4. Architecture

Two roles, two different constraints — each gets the simplest mechanism that meets
its own.

### 4.1 Responder — interrupt-driven

Hard real-time: from poll reception it has `POLL_RX_TO_RESP_TX_DLY_UUS = 650`
(≈667 µs, `ss_twr_responder.c:77`) to read timestamps and arm the delayed reply.
Miss it and the hardware rejects the transmit time as past.

A 10 ms main loop cannot serve this — roughly 15× too slow. So the DW3000 IRQ line
(P1.02) drives the response directly. The main loop is untouched and keeps sleeping
and sampling; an interrupt wakes the CPU in microseconds, so low power and the
deadline are not in tension.

The platform layer already provides the wiring — `dw_irq_init()` and
`port_set_dwic_isr()` (`platform/port.c:79,86`). This is wiring to **enable**, not
to build.

### 4.2 Initiator — bounded blocking

No deadline; it transmits on its own schedule. The existing 10 ms accel tick carries
a counter and every fifth tick (50 ms → 20 Hz) runs one exchange, bounded by
`RESP_RX_TIMEOUT_UUS = 400` (`ss_twr_initiator.c:84`) plus SPI. Worst case delays a
single accel sample. No second timer.

### 4.3 Module boundary

New `Src/uwb/ranging.{h,c}`, mirroring `sensor_ble` (ADR-3), so `sensor_stream.c`
never calls `dwt_*`:

```c
/* Configure the DW3000 for the compiled role. The responder also arms
 * IRQ-driven poll answering. Returns false on any init failure. */
bool ranging_init(void);

/* Initiator only: run one bounded SS-TWR exchange. Returns true and writes
 * *out_mm on success; false on timeout or a result failing sanity checks.
 * Blocks for at most a few ms. */
bool ranging_exchange(uint32_t *out_mm);
```

Role selection reuses the existing `SENSOR_ROLE_INITIATOR` define.

## 5. The gating risk — interrupt latency

Our DW3000 ISR runs at priority 6; the SoftDevice's radio work runs at priority 0
and **preempts it**. A BLE connection event landing on an incoming poll can push the
responder past 667 µs, losing that exchange.

The design **accepts** this loss: that packet carries the sentinel and the next
attempt follows 50 ms later. This is inherent to sharing one CPU with a radio stack.

**The worst-case latency is not yet measured.** Page 4 of the draw.io breaks the
path into eight steps with a blank per step. Until filled, "inside 667 µs" is an
expectation, not a property — so the implementation plan measures it **first**,
before either side's ranging logic is written.

**If the budget fails**, 667 µs is not a hardware limit — it is a constant compiled
into both boards. Raising `POLL_RX_TO_RESP_TX_DLY_UUS` buys time at the cost of a
marginally longer exchange. A failed budget is tuning, not redesign, provided both
roles change together.

## 6. Verification

**No iOS app required.** Two instruments, each proving a different thing:

- **RTT over USB — proves the number is right.** The initiator prints each accepted
  `uwb_mm` in decimal via `test_run_info()` (the M0 pattern), captured to a file with
  `JLinkRTTLogger`. Needed because the criterion is a *delta* between two positions
  and individual readings jitter, so the check requires averaging several samples —
  impractical by reading hex on a phone.
- **nRF Connect — proves the number arrives.** That it reaches bytes 12–15 of the
  packet at ~20 Hz with accel still streaming on both tags.

RTT is bench-only (USB tether). Worn captures need the iOS app and CSV recording,
which is M3/M4.

Line-of-sight bench test, both tags powered, phone connected to both in nRF Connect:

- **Scale is correct:** moving the tags from a tape-measured 1.0 m to 2.0 m changes
  `uwb_mm` by 1.0 m ± ~10 cm. This is the criterion that matters — it proves the
  time-of-flight maths and the fixed-turnaround assumption are right.
- **Absolute offset is recorded, not required.** Any constant error common to both
  distances is uncalibrated antenna delay (stock `16385`), which is a compile-time
  constant correctable later — and correctable retrospectively in recorded CSV,
  since captures store raw `uwb_mm`. Note the figure in the milestone write-up;
  do not fail M2b.1 on it.
- Readings at a fixed distance are **stable** — spread of a few cm, not metres.
- fresh measurements arrive at ~20 Hz
- accel still streams at 100 Hz on **both** tags
- responder's `uwb_mm` stays at the sentinel permanently
- latency budget worksheet (draw.io page 4) filled with measured values

Deliberately line-of-sight: body-blocked behaviour is M2b.2's subject, and mixing
them would confound a coexistence failure with a blockage failure.

## 7. Out of scope

- **NLOS detection and rejection** — M2b.2
- **Antenna delay recalibration** — M4. Stock `TX_ANT_DLY`/`RX_ANT_DLY` = 16385
  stand; M0 measured ~0.73 m *stable* with them, which is not the same as accurate.
  Deliberately deferred: the resulting error is a constant offset (≈33 ps per cm),
  so it can be corrected later by changing two constants — and applied
  retrospectively to recorded captures. Proving the concept now forecloses nothing.
- **Dropout statistics, worn captures, phone-side fusion** — M4
- **iOS app changes** — none; contract unchanged

## 8. Self-review

- Goal, scope split, and rationale stated — §1, §2 ✅
- Contract unchanged and semantics explicit, including sentinel-on-failure — §3 ✅
- Both roles' mechanisms with their differing constraints — §4 ✅
- Module interface typed and matching `sensor_stream.c` call sites — §4.3 ✅
- Gating risk named, with the escape hatch and a measure-first instruction — §5 ✅
- Verification concrete and falsifiable — §6 ✅
- No TBDs. The one unknown (latency budget) is explicitly labelled unmeasured
  rather than assumed ✅
