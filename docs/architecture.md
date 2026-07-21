# TrackingSystem — Architecture (living document)

> **What this is:** the running record of *system-level* decisions — how the pieces
> fit together and why. It is updated as decisions are made, and is meant to be
> reviewed. Per-milestone implementation detail lives in
> `docs/superpowers/specs/` and `docs/superpowers/plans/`; this file is the
> higher-altitude "why".
>
> **Last updated:** 2026-07-21
>
> **Diagrams:** `docs/architecture.drawio` is the canonical hardware,
> execution-context, and software architecture diagram (see §8). Update it in the
> same commit as the change it describes.

---

## 1. What we're building

Two wearable **tags** (Qorvo DWM3001CDK boards, each = UWB radio + 3-axis
accelerometer) and an **iPhone app**. The tags measure motion and their distance
from each other; the phone turns that into a live view the user can see and record.

Concrete Phase-1 goal: both tags stream their sensor readings to the phone over
Bluetooth Low Energy (BLE); the phone timestamps, displays, records, and exports
the data.

## 2. Communication architecture — **tags are data providers, the phone is the brain**

**Decision (ADR-1):** a **star topology**. Each tag is an independent BLE
peripheral that streams *only its own raw data*. The phone is the BLE central; it
connects to both tags, collects their streams, and does all fusion/inference/UI.

```
   Tag A ──BLE──▶ ┐
                  ├──▶  iPhone   (fuses everything, shows + records)
   Tag B ──BLE──▶ ┘
   (A ↔ B talk over UWB only, to measure their separation; A reports that number)
```

**Why this way:**
- Tag firmware stays simple and robust — each tag only reports *its own*
  accelerometer plus (on the initiator) the tag-to-tag distance it already
  computes. No tag needs to understand the other's data.
- The phone has the CPU, screen, and battery for fusion and presentation.
- It matches the already-written, unit-tested iOS packet decoder — so it's the
  path of least work, not extra work.

**Alternatives rejected:**
- *One tag acts as a hub* (relays the other tag's data): adds inter-tag messaging
  and firmware complexity for no benefit at this stage.
- *iPhone-native UWB ranging* (Apple U1): locked-down and not interoperable with
  these boards for this use.

## 3. What the system can measure (and its limits)

- **UWB two-way ranging** between the tags → **one number: the distance between
  them.** Not a full 3D position or direction on its own.
- **Each accelerometer** → that tag's **acceleration (x/y/z)** — the "force"/motion
  signal. Note: the LIS2DH12 is **accelerometer-only (no gyroscope)**, so true
  orientation is limited and drifts. Whether that's good enough vs. a 6/9-axis IMU
  is an explicit Phase-1 validation question (Milestone 4).
- **3D picture** is reconstructed **on the phone** by combining the measurements
  with **user-provided context** — body height and which limb each tag is on — as
  anatomical priors. Priors + measurements → a plausible pose estimate. This is
  phone-side and does **not** change tag firmware.

## 4. Division of responsibility

| | Tags (firmware) | Phone (app) |
|---|---|---|
| Sample accelerometer | ✅ | |
| UWB ranging (initiator computes distance) | ✅ | |
| Emit 16-byte BLE packet, many times/sec | ✅ | |
| Receive both streams, add arrival timestamps | | ✅ |
| Fuse with body model → 3D / metrics | | ✅ |
| Display live view, record CSV, export | | ✅ |

Because the phone does the inference, tag data must be **clean and well-timed**:
the packet carries a `seq` counter (to detect dropped packets) and a
`board_time_ms` timestamp (to align the two tags' streams).

## 5. The wire contract (frozen)

Source of truth: `firmware/ble-contract.md` (created in M2a.2). Summary:

- **Service UUID:** `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
- **Sensor characteristic (notify):** `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
- **Packet — 16 bytes, little-endian:**
  `seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32`
- `uwb_mm = 0xFFFFFFFF` means "no distance from this tag" (the responder always;
  the initiator until live ranging exists).
- **Advertised names by role:** `DWM-INIT` / `DWM-RESP`, so the phone can tell the
  tags apart.

## 6. Roadmap & sequencing decisions

**Decision (ADR-2):** reach the full accel+distance stream in **two safe steps**,
not one. First prove the BLE data pipeline with the accelerometer alone; then
tackle UWB-and-BLE-radio coexistence as an isolated step, so a failure there is
unambiguously the coexistence problem and not a BLE bug.

| Milestone | State | Scope |
|---|---|---|
| M0 — UWB first light | ✅ verified | Two boards range, ~0.73 m stable |
| M1 — Accelerometer | ✅ verified | LIS2DH12 @ 100 Hz |
| M2a.1 — BLE advertising | ✅ verified | Tag visible as `DWM-SENSOR` in nRF Connect |
| M2a.2 — Accel-over-BLE stream | ✅ verified | GATT notify characteristic; stream `seq/time/accel`, `uwb_mm` = sentinel — [spec](superpowers/specs/2026-07-18-ble-sensor-stream-design.md) |
| M2b.1 — Live UWB in the stream | ✅ verified | Concurrent UWB ranging + BLE; initiator reports real `uwb_mm`, line-of-sight — [spec](superpowers/specs/2026-07-19-m2b1-uwb-in-stream-design.md) |
| **M3a — iOS live view + link measurement** | ⬜ **next** | Connect both tags, live numbers, measure real packet rate / loss — [spec](superpowers/specs/2026-07-21-m3a-ios-live-view-design.md) |
| M3b — Capture recording | ⬜ | Start/stop capture, CSV persistence, export, background operation |
| M2b.2 — Non-line-of-sight rejection | ⬜ | Body blocks 6.5 GHz; reject reflected-path readings via `dwt_nlos_ipdiag()`, threshold from measured worn data (needs M3b to record it) |
| M4 — Validation | ⬜ | Bench + worn captures; answer the four spec questions |

## 7. Decision log

- **2026-07-18 — ADR-1: Star topology, tags as data providers.** Each tag streams
  only its own data; the phone fuses. Rejected hub-relay and iPhone-native UWB.
- **2026-07-18 — ADR-2: Sequence M2a.2 (accel-only) before M2b (UWB coexistence).**
  Isolate the risky radio-sharing step from first-time GATT streaming.
- **2026-07-18 — ADR-3: M2a.2 tag firmware behind a two-function `sensor_ble`
  interface** (`sensor_ble_init` / `sensor_ble_notify`), with `app_timer`-driven
  100 Hz sampling and sleep-between (no busy-wait), so `main.c` never touches
  `sd_*`. Detail in the M2a.2 spec.
- **2026-07-19 — M2a.2 verified:** `DWM-INIT` and `DWM-RESP` both stream accel
  packets over the sensor characteristic in nRF Connect (`uwb_mm` = sentinel).
  Working initiator image stashed locally at `firmware/hex/sensor_stream_init.hex`
  (untracked — rebuild from this commit to reproduce it).
- **2026-07-19 — ADR-4: Split M2b into M2b.1 (mechanism) and M2b.2 (signal
  quality).** The human body blocks 6.5 GHz substantially, and a blocked direct
  path with a surviving reflection yields an exchange that *succeeds but reports
  too long a distance* — a plausible-looking wrong answer that the 50 m sanity
  clamp cannot catch. Rejecting it needs `dwt_nlos_ipdiag()` and a threshold, but
  a guessed threshold fails invisibly: over-rejection is indistinguishable from
  blockage. So M2b.1 proves the pipeline line-of-sight and M2b.2 sets the cutoff
  from a measured body-blocked run. Same reasoning as ADR-2.

- **2026-07-19 — M2b.1 verified on the bench.** Initiator streams real `uwb_mm`
  at ~21 readings/sec while both tags stream accel at 100 Hz.
  - **Scale (pass criterion):** 150 cm → median 1454 mm; 50 cm → median 487 mm;
    delta **967 mm** for a 1000 mm move (tolerance ±100).
  - **Stability:** σ = 20 mm at 50 cm (82% within one 100 mm bucket);
    σ = 100 mm at 150 cm with a ~9% tail reading ~250 mm long — visible multipath,
    which is M2b.2's target.
  - **Absolute offset:** −13 mm at 50 cm, −46 mm at 150 cm → a constant ≈ −30 mm,
    the antenna-delay signature. Recorded, not corrected (deferred to M4).
  - **Deadline:** worst margin 196 µs of 650 µs with BLE connected;
    `late=4` of 537 exchanges (**0.7%** lost to SoftDevice preemption), surfacing
    as sentinels rather than stale values — the accepted failure mode, now measured.
  - **Process note:** several apparent "failures" during this bench session were
    stale RTT buffer and imprecise reference distances, not firmware. See
    `firmware/FLASHING.md` §6a — always reset before a measurement capture.

- **2026-07-21 — ADR-5: Split M3 into M3a (connect + measure) and M3b (record),
  and sequence both ahead of M2b.2.** Two decisions, one cause.

  *The split:* nobody has measured what fraction of the 100 Hz stream actually
  reaches the phone. The firmware pushes one notify per 10 ms tick per board and
  never checks whether `sd_ble_gatts_hvx` accepted it; nRF Connect showed data
  flowing, which is not the same claim as no loss. Recording is the easy, tested
  half (`CaptureWriter` exists); throughput is the half that could force firmware
  changes. Building the recorder first risks finding out afterwards that the data
  it faithfully recorded was half missing. So M3a measures, M3b records.

  *The reorder:* ADR-4 requires M2b.2's rejection threshold be set from measured
  body-blocked data with **worn** antennas. Today's only instrument is RTT over a
  USB tether — bench-only, as the M2b.1 spec states in §6. M2b.2 therefore cannot
  currently source the data its own ADR demands. M3 builds that instrument, so
  M2b.2 follows M3b.

  M3a sets **no pass bar** — the measured figure is the deliverable, and M3b
  proceeds regardless. Same posture as M2b.1 Task 1: measure before building on
  the assumption. See [spec](superpowers/specs/2026-07-21-m3a-ios-live-view-design.md).

## 8. System architecture diagrams

**Canonical source: [`docs/architecture.drawio`](architecture.drawio)** — three pages:

| Page | Shows |
|---|---|
| 1 · Hardware | Chips, buses, pin assignments, antennas |
| 2 · Execution and Priorities | NVIC priorities, preemption order, the M2b deadline |
| 3 · Software layers | Module boundaries and what each layer may call |
| 4 · Interrupt path and latency budget | The poll-RX-to-reply-armed chain, step by step, with the **measurement worksheet** for M2b |

Page 4 is the one that decides whether M2b works. Pages 1–3 show structure —
the wire, the priority ranking, the module boundaries. Page 4 shows *behaviour
over time*: the eight steps between a poll landing and the reply being armed,
each with a blank to be filled by measurement. **Every duration on it is
currently unknown**, including the dominant term (SoftDevice preemption), and
the block widths are placeholders rather than data.

Open it in [diagrams.net](https://app.diagrams.net), the VS Code *Draw.io
Integration* extension, or the desktop app. It is uncompressed XML on purpose, so
it diffs in review. **Edit the diagram in the same commit as the change it
describes** — a stale architecture diagram is worse than none.

The reference data below is duplicated here as text so it stays greppable and
readable without opening a tool. Every value is read from the source; file
references are given so each can be re-checked rather than trusted.

### 8.1 Radios — no RF coexistence problem

UWB and BLE are **separate chips in separate bands with separate antennas**:

| Radio | Chip | Band | Peripheral |
|---|---|---|---|
| UWB | DW3110 | channel 5, 6489.6 MHz | SPIM3 + GPIOTE |
| BLE | nRF52833 internal | 2.4 GHz | RADIO (owned by S112) |

All contention between them is for **CPU attention**, not airwaves — see §8.3.

### 8.2 Pin and peripheral map

| Signal | Pin | Peripheral | Ref |
|---|---|---|---|
| DW3000 SCK | P0.03 | SPIM3 | `custom_board.h:105` |
| DW3000 MOSI | P0.08 | SPIM3 | `custom_board.h:107` |
| DW3000 MISO | P0.29 | SPIM3 | `custom_board.h:106` |
| DW3000 CS | P1.06 | SPIM3 | `custom_board.h:108` |
| DW3000 RST | P0.25 | GPIO | `custom_board.h:111` |
| **DW3000 IRQ** | **P1.02** | **GPIOTE** | `custom_board.h:110` |
| Accel SCL | P1.04 | TWIM1 @ 400 kHz | `accel/accel.c:12` |
| Accel SDA | P0.24 | TWIM1 @ 400 kHz | `accel/accel.c:13` |

SPI instance: `platform/deca_spi.c:69` (SPIM3). Accel address `0x19`
(`accel/accel.c:29`). SPIM3 and TWIM1 are distinct instances — no conflict.

### 8.3 Execution contexts and NVIC priorities

S112 reserves priorities 0, 1 and 4, and **cannot be preempted or deferred** by
application code.

| Pri | Context | Work | Deadline |
|---|---|---|---|
| 0 | S112 SoftDevice *(reserved)* | BLE radio / link timing | hard, SD-owned |
| 1 | S112 SoftDevice *(reserved)* | BLE stack | hard, SD-owned |
| 2–3 | free | — | — |
| 4 | S112 SoftDevice *(reserved)* | SVC / SD API calls | — |
| 5 | free | — | — |
| **6** | **GPIOTE P1.02 → `deca_irq_handler` → `process_deca_irq` → `dwt_isr`** | DW3000 RX/TX events; responder reads timestamps and arms the delayed reply | **650 µs** ← M2b |
| 7 | RTC1 `app_timer` | 10 ms tick, sets flags | soft |
| — | thread mode (`sensor_stream.c`) | accel read, pack 16 B, `hvx` notify, initiator `ranging_exchange()`, `sd_app_evt_wait()` | none |

Preemption order: `0,1,4` → `6` → `7` → thread mode.

Refs: `sdk_config.h:1392` (GPIOTE pri 7), `:1920` (NRFX_GPIOTE pri 6),
`:6124` (`app_timer` pri 7).

**Residual risk (M2b).** A SoftDevice radio event at priority 0 preempts the
priority-6 DW3000 ISR. If that delay pushes past 650 µs, the exchange is lost.
The design **accepts** this: that packet carries `0xFFFFFFFF` and the next
attempt follows 50 ms later. This is inherent to sharing one CPU with a radio
stack, not a flaw in the design.

**MEASURED 2026-07-19 (M2b.1 Task 1).** With BLE **connected** and 119 polls
observed, the worst deadline margin was **196 µs of the 650 µs budget** (~30%
headroom). The same firmware with BLE only advertising showed 390–418 µs, so
SoftDevice preemption costs ~200 µs — confirming it is the dominant term, as the
design assumed. **Pass**: no change to `POLL_RX_TO_RESP_TX_DLY_UUS` required.
Caveat: 119 polls (~2 min at 1 Hz) is a small sample for a worst case; the
`late=` counter added in Task 2 measures missed deadlines directly and is the
stronger evidence.

**Historical note — the open item this replaced.** The worst-case latency for the
priority-6 path was **not measured**. Until it is, "comfortably inside 650 µs" is a design expectation, not
a verified property. Page 4 of the draw.io breaks that path into eight steps with
a blank per step; fill it during implementation using a GPIO toggle on a scope
for the entry latency and `DWT->CYCCNT` deltas (15.6 ns/tick @ 64 MHz) for the
ISR body.

**If the budget fails**, 650 µs is not a hardware limit — it is
`POLL_RX_TO_RESP_TX_DLY_UUS = 650` (`ss_twr_responder.c:77`), a constant compiled
into both boards. Raising it buys the responder time at the cost of a marginally
longer exchange. A failed budget is therefore a tuning problem, not a redesign,
provided initiator and responder are changed together.

### 8.4 Software layering

Each hardware concern sits behind a two-function module, so the application never
calls `sd_*`, `dwt_*` or `nrfx_*` directly (ADR-3).

```
sensor_stream.c          thread mode · 10 ms tick · builds the 16-byte packet
    ├── sensor_ble.[ch]  _init / _notify   ──▶  nrf_sdh / S112
    ├── ranging.[ch]     _init / _exchange ──▶  decadriver dwt_*  ──▶  platform/
    │   NEW in M2b                                                     deca_spi.c
    └── accel.[ch]       _init / _read     ──▶  nrfx_twim              port.c
```

Only `ranging.[ch]` is new in M2b. `sensor_ble.c`, `accel.c` and the platform
layer are unchanged — `platform/port.c:79,86` already provides `dw_irq_init()`
and `port_set_dwic_isr()`, so the DW3000 interrupt is wiring to **enable**, not
wiring to build.

## 9. Known issues (robustness debt)

Deliberately unfixed, recorded so they are not rediscovered from scratch.

### 9.1 A failed init hangs the tag silently — no recovery, no indication

**Severity: high for worn use. Found 2026-07-21 during M3a bring-up.**

Both tags were found hung in `for (;;) {}` inside `sensor_stream()`'s
`accel_init()` failure path. Because `accel_init()` runs **before**
`sensor_ble_init()`, a hung board never starts advertising: the phone sees
nothing at all, and the board gives no LED, no packet, and no error anywhere
an untethered user could observe it. A plain MCU reset cleared it on both
boards, so the trigger was transient peripheral state — most plausibly an I2C
transaction interrupted at power-down leaving the LIS2DH12 unresponsive, since
`accel_init()` fails only when `WHO_AM_I` reads back wrong at *both* candidate
addresses (`accel.c:71-77`).

The same pattern applies to `sensor_ble_init()` and `ranging_init()`: every
init failure in `sensor_stream()` ends in an infinite loop.

**Why this matters beyond the bench.** Tethered, it cost ~20 minutes with a
J-Link to diagnose. Worn, it is a tag that appears to be recording and is not —
discovered only afterwards, as a capture that stops for no visible reason.

**Fix when M3b or M4 touches firmware:** retry `accel_init()` a few times with a
short delay; on continued failure, **carry on and advertise anyway** with a
status bit in the packet marking the accelerometer dead, rather than hanging.
A tag that reports "my accelerometer is broken" is far more useful than one
that vanishes. Note this needs a byte in the wire contract, which is frozen —
so it is a contract change, not a drop-in patch.

**Diagnostic worth reusing:** `JLinkRTTLogger` reported "RTT Control Block not
found" and was a dead end. Dumping RAM (`savebin ram.bin 0x20000000 0x20000`)
and running `strings` over it recovered the firmware's printed output directly,
which is what named the failure. Sampling `PC` several times distinguished a
tight hang loop (identical address every sample) from normal idling in
`sd_app_evt_wait()`.
