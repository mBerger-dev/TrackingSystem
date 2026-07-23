# M3b — Capture recording (design)

**Date:** 2026-07-23
**Status:** approved, ready for implementation plan
**Milestone:** M3b (see `docs/architecture.md` §6 roadmap)
**Depends on:** M3a merged — the app connects to both tags, decodes the 16-byte
packet, and measures the link (`SensorPacket`, `LinkStats`, `BoardLink`,
`BoardModel`, `LiveView`). `CaptureWriter` (CSV row formatter) already exists and
is tested.

## 1. Goal

Record a session to disk and get it off the phone. Press Start (with an optional
label), do the exercise while watching the live panels, press Stop — the result is
**one CSV** holding both tags' samples time-ordered together, shareable to a laptop
in one tap.

These recordings are the raw material for later milestones: M2b.2 needs measured
body-blocked distance data to set an NLOS threshold, and M4 judges the accelerometer
signal from exported CSV on a laptop. M3b produces those files.

## 2. Scope

**In:** foreground recording — the phone is open and monitored during the session.
Manual Start/Stop. One combined CSV per session. In-app session list with per-session
share (iOS share sheet → AirDrop / Mail / Files) and delete.

**Out (YAGNI):**
- **Background / pocket recording.** The eventual target, explicitly deferred. The
  design leaves a clean seam for it (§4.4) but builds none of it now.
- In-app plotting or CSV viewing — the signal is judged on a laptop (M4).
- Editing or renaming a session after Stop — rename on the Mac.
- Multiple simultaneous recordings.

### 2.1 Prerequisite — fix known issue §9.2 first (separate, firmware)

`docs/architecture.md` §9.2: a failed `dwt_starttx()` can spin the initiator's main
loop forever (`Src/uwb/ranging.c:230` ignores the return; `waitforsysstatus()` has no
software timeout). Symptom is a tag that stays *connected* but stops sending — which
is **exactly what a stalled capture looks like**, and would be easy to misattribute to
the phone, the link, or the recorder. Fix it before recording so a real capture stall
has one fewer innocent suspect. This is an independent firmware change (check the
`dwt_starttx()` return, bound the wait, emit the sentinel on failure) and can land as
its own small PR ahead of the recording work.

## 3. What counts as done

**SensorCore (off-hardware):** `CaptureSession` unit tests pass — header written
exactly once, N synthetic packets produce N rows, formatted values match
`CaptureWriter`, both-board interleaving is correct, and an empty session still yields
a valid header-only file.

**Device:** a ~1–2 minute recording with both tags, then Stop → Share → open on the
Mac, showing:
- both boards present, `seq` monotonic per board within the file
- `uwb_mm` populated for `DWM-INIT`, blank for `DWM-RESP`
- row count ≈ observed rate × duration
- `phone_arrival_ms` starting near 0 and advancing monotonically

## 4. Architecture

Extends the M3a structure. The split mirrors ADR-3 and the M3a boundary: the logic
that can be checked without a radio lives in `SensorCore`; only the parts that
genuinely need the device live in the app.

```
ios/
  SensorCore/Sources/SensorCore/
    CaptureWriter.swift     CSV row formatting          exists, tested
    CaptureSession.swift    file + streaming writes     NEW
  TrackingApp/TrackingApp/
    RecordingController.swift  start/stop, files, share  NEW
    BoardModel.swift        forwards packets to recorder  edit
    LiveView.swift          record bar + session list     edit
```

### 4.1 `CaptureSession` (SensorCore — pure Foundation, testable)

Owns one output file and a **dedicated serial `DispatchQueue`** that is the only thing
touching the file handle. Interface:

- `init(url:)` / `start()` — create the file, write the `CaptureWriter` header once.
- `append(board:packet:arrivalMs:)` — enqueue one formatted row onto the serial queue.
- `close()` — flush and close; safe to call once, idempotent.

It reuses `CaptureWriter` for row formatting and knows nothing about CoreBluetooth,
SwiftUI, or `FileManager` locations (it's handed a URL). This is what makes it
testable against a temp file, and what makes a dropped or duplicated row a caught
test failure rather than a surprise in analysis weeks later.

### 4.2 `RecordingController` (TrackingApp — `@Observable`)

The device-specific half. Owns:

- **State:** `isRecording`, the editable `label`, elapsed time, and a live row count
  (total and per board) for on-screen monitoring.
- **Start:** resolve `<label>-YYYY-MM-DD-HHMMSS.csv` in the app's Documents directory
  (label sanitized; default `session`; seconds in the name avoid collisions), open a
  `CaptureSession`, and mark the session's monotonic start time.
- **`append(role:packet:arrival:)`:** a no-op unless recording; otherwise compute
  `phone_arrival_ms = (arrival − sessionStart) × 1000` and forward to the session.
- **Stop:** close the session, add the file to the session list.
- **Sessions:** enumerate Documents for `.csv`, newest first; expose each file URL for
  a SwiftUI `ShareLink`; support delete.

### 4.3 Data flow and threading

`AppModel` owns the single `RecordingController` and injects it into each `BoardModel`.
Each board forwards **every** packet to the recorder from inside its existing
`onPacket` closure — i.e. at the full ~100 Hz on the BLE queue, *before* the 10 Hz UI
throttle — so the capture is complete even though the panels refresh slowly.

Two BLE queues call `append` concurrently (~200 rows/s combined). `CaptureSession`'s
serial queue serialises the writes and keeps disk I/O off both the radio queues and
the main thread. Rows land in **arrival order**; the `board` column distinguishes them.

**Disconnect mid-capture is not a special case.** Recording is time-based, not
connection-based: a dropped tag contributes no rows during its gap, and the gap is
reconstructable from `seq` / `board_time_ms` — the same stance as loss measurement.
The file stays open until Stop.

### 4.4 The foreground boundary (and the seam for later)

Foreground-only is enforced honestly: **if the app is backgrounded while recording, it
auto-Stops and finalizes the file.** The result is a clean, shorter CSV — never a
truncated or corrupt one. This is observed via SwiftUI `scenePhase`. When background
recording is built later, this is the exact seam it replaces: instead of finalizing on
background, the app will request a `bluetooth-central` background mode and keep the
session open.

## 5. UI

One screen, extending `LiveView`:

- **Record bar** above the board panels. Idle: label text field + Start. Recording: a
  REC indicator, the label, an elapsed timer, Start replaced by Stop, and the live row
  count (total · per board) — the climbing counter is the "it's actually working"
  signal.
- **Sessions list** below the panels: recorded files newest-first, each showing name,
  duration, and row count, with a `ShareLink`. Swipe-to-delete.

## 6. Risks

- **Disk write jitter.** At ~200 rows/s, formatting and appending on the serial queue
  is cheap, but a stall there must not back-pressure the BLE queues. `append` only
  enqueues; it never blocks on I/O. If the queue ever fell behind, it would cost
  recorder memory, not dropped BLE packets — and the tests exercise sustained volume.
- **Free provisioning still applies** — a stale build won't launch after 7 days;
  re-deploy before a session (see `ios/README.md`).
- **Simulator can't do any of this** — CoreBluetooth needs the phone; the device
  criteria in §3 require hardware.

## 7. Verification

- **`CaptureSession` unit tests** on macOS, per §3 (header-once, row count, value
  match, interleaving, empty session).
- **Device run** per §3, on a phone with both tags powered and flashed.
- The §9.2 firmware fix is verified separately as part of its own change.

## 8. Self-review

- Goal and the concrete artifact (one shareable CSV) stated — §1 ✅
- Scope bounded; background deferred with a named seam rather than hand-waved — §2, §4.4 ✅
- Prerequisite (§9.2) called out with the reason it comes first — §2.1 ✅
- Done criteria split into off-hardware and device — §3 ✅
- Module boundary matches the M3a/ADR-3 pattern and is justified on testability — §4 ✅
- Threading and the 100 Hz tap point specified; disconnect behaviour stated, not assumed — §4.3 ✅
- Risks named, including the one that could corrupt the measurement (write back-pressure) — §6 ✅
- No TBDs
