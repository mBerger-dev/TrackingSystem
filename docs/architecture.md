# TrackingSystem — Architecture (living document)

> **What this is:** the running record of *system-level* decisions — how the pieces
> fit together and why. It is updated as decisions are made, and is meant to be
> reviewed. Per-milestone implementation detail lives in
> `docs/superpowers/specs/` and `docs/superpowers/plans/`; this file is the
> higher-altitude "why".
>
> **Last updated:** 2026-07-19
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
| **M2b — Live UWB in the stream** | ⬜ **next** | Concurrent UWB ranging + BLE; initiator reports real `uwb_mm` |
| M3 — iOS app | ⬜ (core logic tested) | Central, live view, CSV record/export |
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
  Working initiator image stashed at `firmware/hex/sensor_stream_init.hex`.

## 8. System architecture diagrams

**Canonical source: [`docs/architecture.drawio`](architecture.drawio)** — three pages:

| Page | Shows |
|---|---|
| 1 · Hardware | Chips, buses, pin assignments, antennas |
| 2 · Execution and Priorities | NVIC priorities, preemption order, the M2b deadline |
| 3 · Software layers | Module boundaries and what each layer may call |

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
| **6** | **GPIOTE P1.02 → `deca_irq_handler` → `process_deca_irq` → `dwt_isr`** | DW3000 RX/TX events; responder reads timestamps and arms the delayed reply | **667 µs** ← M2b |
| 7 | RTC1 `app_timer` | 10 ms tick, sets flags | soft |
| — | thread mode (`sensor_stream.c`) | accel read, pack 16 B, `hvx` notify, initiator `ranging_exchange()`, `sd_app_evt_wait()` | none |

Preemption order: `0,1,4` → `6` → `7` → thread mode.

Refs: `sdk_config.h:1392` (GPIOTE pri 7), `:1920` (NRFX_GPIOTE pri 6),
`:6124` (`app_timer` pri 7).

**Residual risk (M2b).** A SoftDevice radio event at priority 0 preempts the
priority-6 DW3000 ISR. If that delay pushes past 667 µs, the exchange is lost.
The design **accepts** this: that packet carries `0xFFFFFFFF` and the next
attempt follows 50 ms later. This is inherent to sharing one CPU with a radio
stack, not a flaw in the design.

**Open item (M2b).** The worst-case latency for the priority-6 path is **not yet
measured**. Until it is, "comfortably inside 667 µs" is a design expectation, not
a verified property.

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
