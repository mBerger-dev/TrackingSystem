# Phase 1: Sensor Streaming Foundation — Design

**Date:** 2026-07-13
**Status:** Approved (design), pending implementation plan
**Author:** Marius Berger (with Claude)

## Context

Building a gym exercise tracking system. Long-term vision: determine which
exercise is being performed, estimate exertion (bar speed, ideally bar path),
provide post-session review, and eventually train an ML model from amassed data
to improve exercise prediction.

Hardware on hand: **two Qorvo DWM3001CDK development kits**. Each DWM3001C module
integrates:
- **DW3110** ultra-wideband (UWB) transceiver
- **Nordic nRF52833** MCU with Bluetooth LE
- **ST LIS2DH12** 3-axis accelerometer (low-power economy grade; ±2/4/8/16 g).
  *Note:* no gyroscope and no magnetometer on the stock module. The module
  schematic reportedly has footprints for a 6-axis (LSM6DSR) or 9-axis (BNO055)
  alternate, which is relevant to future production-hardware decisions but is not
  populated on the stock kit.

Intended wear: one board on the **wrist**, one on the **ankle**, powered by an
external powerbank during testing. Target production topology (future): BLE
stream to an iPhone that stores and syncs the data, Garmin-style, because the
on-module flash is too small to hold full sessions.

**This spec covers only Phase 1**: proving the hardware and producing clean,
well-understood raw data to build on. It is a deliberate starting point — from
the data it produces, we decide whether additional/different hardware is needed.

## Goal

Both boards stream 3-axis acceleration + the UWB inter-board distance over BLE to
an iOS app that timestamps, displays live, records, and exports raw data — so
real captures can be inspected and we can judge what is buildable on this
hardware.

## Non-goals (explicitly out of scope for Phase 1)

- Exercise classification / determination
- Bar-path reconstruction
- Sensor fusion / velocity/exertion math
- Any post-session review UI
- Any ML model or training loop

These are later sub-projects that consume Phase 1 data.

## Hardware reality that shapes the design

- UWB and BLE use **separate radios** (DW3110 for UWB, nRF52833 for BLE), so a
  board can do UWB ranging and act as a BLE peripheral concurrently.
- With only 3-axis accelerometer and no gyro, **true 3D bar-path reconstruction
  is likely out of reach** on this hardware; bar *speed* (magnitude) may be
  feasible later via accel + UWB. Full orientation/path is a candidate
  production-hardware recommendation (needs a 6/9-axis IMU).
- The usable per-board signal is therefore: **3-axis acceleration + one changing
  UWB distance** between the two boards. Still a distinctive feature set for later
  classification work.

## Architecture and roles

Chosen approach: **two independent BLE peripherals** (evaluated against a
"hub board" relay and a "phone does all ranging math" approach; chosen for
simplest per-board firmware, independent debuggability, and because it directly
exposes the real-world timing jitter we want to measure).

- **Board A — "Initiator":** drives UWB two-way ranging (TWR), so it holds the
  wrist↔ankle distance. Reads its own accelerometer. Acts as BLE peripheral.
- **Board B — "Responder":** answers UWB ranging, reads its own accelerometer.
  Acts as BLE peripheral.
- **iPhone — BLE central:** connects to both boards, parses both streams,
  timestamps them, stores them.

Role is a build-time choice. The **wrist vs ankle** assignment is a *label chosen
in the app* at record time; the firmware is agnostic to which limb a board is on.

## Firmware (C, per board)

Built by **modifying Qorvo's example firmware** for the DWM3001CDK (which already
performs TWR + BLE on the nRF52833 + DW3110), rather than a from-scratch or clean
Zephyr rebuild — fastest honest path to validated data, and keeps us in the C
codebase. Each board:

- Runs **UWB two-way ranging** with the other board at ~10–20 Hz.
- Reads the **LIS2DH12** accelerometer at a fixed **100 Hz**.
- Exposes a **BLE GATT service** with a notify characteristic that streams
  packets of the form:
  `{ seq, board_time_ms, accel_x, accel_y, accel_z, uwb_distance* }`
  (*`uwb_distance` present on the initiator only).
- Includes **its own millisecond timestamp** in every packet, so cross-board
  timing jitter can be measured rather than assumed away.

## iOS app (Swift + CoreBluetooth)

Deliberately a **data instrument, not a product**:

- Scan for and connect to both boards by service UUID; degrade gracefully if only
  one board is present; auto-reconnect on drop.
- **Live view:** per-board connection status, live accel values (simple plot),
  current UWB distance, and packet rate / loss %.
- **Record:** start/stop a capture; tag it with an exercise name and which board
  is wrist vs ankle.
- **Persist:** write each capture as a **CSV** on-device with columns:
  board id, sequence, board_time_ms, phone_arrival_time, accel_x/y/z,
  uwb_distance.
- **Export:** share the CSV via Files / AirDrop for laptop-side analysis.

## Data flow and timestamping

```
sample → BLE notify → phone parses → adds phone arrival timestamp
       → in-memory buffer → (on record) append to CSV → export
```

Every packet carries **two timestamps**: the board's own clock and the phone's
arrival time. This is intentional — it lets us quantify BLE latency/jitter and
how far the two boards' clocks drift apart, which tells us whether a production
design needs the tighter-sync "hub" architecture.

## What Phase 1 is designed to answer

1. Is the LIS2DH12 accelerometer clean and high-enough resolution for gym
   movement?
2. Does the UWB distance track wrist↔ankle separation usefully and stably?
3. How bad is BLE jitter / cross-board time sync in practice?
4. Are distinguishable movement signatures visible by eye across different
   exercises in the exported data?

## Testing strategy

Bench-first, then worn:
1. Move a board by hand; confirm accelerometer axis directions and scale.
2. Separate the two boards physically; confirm UWB distance rises/falls
   correctly and is stable at rest.
3. Measure packet-loss rate at expected wear range.
4. Record a handful of real worn captures across a few different exercises and
   inspect the exported CSVs.

## Decisions captured

- **Analysis path:** CSV export to laptop (not in-app charting) for Phase 1.
- **Firmware base:** start from Qorvo's example firmware, not a clean Zephyr
  rebuild.
- **Sample rates:** 100 Hz accelerometer, ~10–20 Hz UWB ranging.
- **Coordination:** two independent BLE peripherals (Approach A).

## Where this sits in the larger roadmap

Each item below is its own future spec → plan → build cycle:

1. **Sensor streaming foundation** — *this spec.*
2. Data inspection & recording (labeling, dataset export, visualization).
3. Exercise determination (classification).
4. Exertion (bar speed / path) via fusion.
5. Post-session review UI.
6. ML training loop (feeds back into 3 and 4).
