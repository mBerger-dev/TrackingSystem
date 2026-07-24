# Squat Playback Prototype — Design (v1)

**Date:** 2026-07-24
**Status:** approved, ready for plan
**Scope:** a rudimentary, honest playback of a recorded squat capture — the first
step toward the system's end goal of a *simulated view of the user's exercise*.

## Purpose

Turn a recorded capture CSV into an animated, scrubbable side-on view that
reconstructs the exercise from the sensor data. This is a throwaway **prototype**
to nail the visual and the reconstruction math cheaply; the reconstruction logic
later ports into the iOS app / `SensorCore`.

Source capture for v1: `squat-2026-07-24-140108.csv` — ~19.1 s, two tags streaming
accel at ~100 Hz (INIT 1810 rows, RESP 1912), 350 UWB distance readings ranging
900–2851 mm. Tag placement for this capture: **one tag on the outside of the ankle,
the other in the opposing hand** held out front in a squat-style pose. This is a
test capture, not a clean biomechanical squat.

## What is honestly recoverable (and what is not)

We have, per tag, a 3-axis accelerometer (no gyro), plus one scalar UWB distance
between the two tags. From this:

- **Real, from the data:**
  - Each tag's **tilt** — for slow motion the accelerometer reads the gravity
    vector, i.e. how far the tag has rotated from its resting orientation.
  - The **ankle↔hand distance** — the strongest rep signal here; the hand travels
    down toward the planted foot each rep, so the distance shrinks and grows.
- **NOT recoverable (drawing assumptions, not measurements):**
  - Direction of the hand relative to the ankle — we have a scalar distance only,
    no bearing. So the hand cannot be truly *placed* in space.
  - An anatomically correct human figure — would require inventing the missing
    geometry. Explicitly out of scope.

Honesty rule: the animation must be **driven by this capture**, never a canned
scripted squat that ignores the data.

## Deliverable

A single self-contained `squat-playback.html` (no server, no external assets, no
file picker). This capture's data is embedded directly in the page. Opens in a
browser on the Mac.

## Data pipeline (in-page JS, transparent)

1. **Embed** decoded samples: two arrays (INIT / RESP), each `{t, ax, ay, az}` in
   g; plus sparse distance readings `{t, mm}`. `t` = `phone_arrival_ms`
   (merged phone clock, 0–19129 ms).
2. **Gravity → tilt.** Low-pass each tag's accel (removes fast motion-acceleration
   so gravity dominates), then compute tilt as the angle between the current
   (smoothed) gravity vector and the capture's **mean gravity direction** (the
   tag's resting orientation). Placement-agnostic; no hard-coded "up" axis. A
   signed angle within the tag's dominant-gravity plane so the figure tilts both
   ways.
3. **Distance.** Hold/interpolate the sparse UWB between readings; clamp obvious
   multipath spikes (the ~2.85 m tail) so a single bad reflection does not yank
   the figure.

## The view (2D side-on)

- A **planted foot/ankle** at a fixed base point, tilting with the ankle tag.
- A **hand marker** drawn at the current UWB distance from the ankle along a fixed
  forward-diagonal, tilting with the hand tag.
- A faint **connecting line/bar** whose length = distance — the visible rep pump.
- A **swap toggle** (which board is ankle vs hand) so INIT/RESP need not be
  correct up front.
- A live **readout**: current time, distance, and each tag's tilt.

## Transport controls

Play / pause, a **scrubber** (0–19 s), speed (0.5× / 1× / 2×), loop.

## Out of scope for v1

Anatomically correct human figure; rep counting; left/right discrimination; any
3D; loading arbitrary CSVs. All deferred — v1 is the honest minimum that animates
*this* capture and gives an engine to grow.

## Growth path

Same engine upgrades to a truer figure as tag placement becomes deliberate (e.g.
torso + thigh gives real hip/knee bend). Reconstruction math (gravity→tilt,
distance interpolation) is written to be portable into `SensorCore` later.
