# TrackingSystem — Architecture (living document)

> **What this is:** the running record of *system-level* decisions — how the pieces
> fit together and why. It is updated as decisions are made, and is meant to be
> reviewed. Per-milestone implementation detail lives in
> `docs/superpowers/specs/` and `docs/superpowers/plans/`; this file is the
> higher-altitude "why".
>
> **Last updated:** 2026-07-18

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
| **M2a.2 — Accel-over-BLE stream** | ⬜ **next** | GATT notify characteristic; stream `seq/time/accel`, `uwb_mm` = sentinel |
| M2b — Live UWB in the stream | ⬜ | Concurrent UWB ranging + BLE; initiator reports real `uwb_mm` |
| M3 — iOS app | ⬜ (core logic tested) | Central, live view, CSV record/export |
| M4 — Validation | ⬜ | Bench + worn captures; answer the four spec questions |

## 7. Decision log

- **2026-07-18 — ADR-1: Star topology, tags as data providers.** Each tag streams
  only its own data; the phone fuses. Rejected hub-relay and iPhone-native UWB.
- **2026-07-18 — ADR-2: Sequence M2a.2 (accel-only) before M2b (UWB coexistence).**
  Isolate the risky radio-sharing step from first-time GATT streaming.
