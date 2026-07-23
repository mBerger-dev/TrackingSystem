# M3a — iOS live view and link measurement (design)

**Date:** 2026-07-21
**Status:** approved, ready for implementation plan
**Milestone:** M3a (see `docs/architecture.md` §6 roadmap)
**Depends on:** M2b.1 verified (both tags stream accel at 100 Hz; initiator reports
real `uwb_mm`), `SensorCore` package (decoder + CSV writer, 7 passing tests)

## 1. Goal

An iPhone app connects to both tags over BLE and shows, per board: connection
state, packets/sec, loss %, and the latest accel and `uwb_mm` values.

Its real output is a **number nobody has yet measured** — what fraction of the
100 Hz stream actually reaches the phone.

## 2. Scope split (ADR-5)

M3 as written in the foundation spec (`2026-07-13-sensor-streaming-foundation-design.md`
§"iOS app") bundles connect, live view, record, CSV, and export. Split, for the same
reason as ADR-2 and ADR-4:

- **M3a (this spec)** — connect and measure. Ends knowing the link's real
  throughput and loss.
- **M3b (deferred)** — capture recording, CSV persistence, export, and background
  operation for worn sessions.

Rationale: recording is the easy half and the well-understood half — `CaptureWriter`
already exists and is tested. Throughput is the half that could force **firmware**
changes rather than app changes. Building the recorder on top of an unmeasured link
risks discovering, after the recorder exists, that the data it faithfully recorded
was half missing.

### 2.1 Why this milestone was reordered ahead of M2b.2

The roadmap had M2b.2 (non-line-of-sight rejection) next. M2b.2's deliverable is a
rejection threshold that ADR-4 requires be set **from measured body-blocked data with
worn antennas** — explicitly not from the Qorvo example's generic figures. The only
instrument available today is RTT over a USB tether, which is bench-only; the M2b.1
spec says so directly (§6). So M2b.2 currently cannot source the data its own ADR
demands. M3 builds that instrument. M2b.2 follows M3b.

## 3. What M3a measures, and what counts as done

**Done** = a 5-minute run with both boards connected, with the observed per-board
rate and loss figures recorded in `docs/architecture.md`.

**There is deliberately no pass bar.** The figure is the deliverable; what to do
about it is a separate decision made with the number in hand. This mirrors M2b.1
Task 1, where the interrupt-latency margin was measured before anything was built
on the assumption.

Consequence, stated so it is not a surprise later: **M3b proceeds regardless of the
number.** A bad result does not block recording — it opens its own scoped piece of
work, and captures recorded in the meantime carry `seq`, so loss is reconstructable
retrospectively from any CSV.

For context when reading the result: human movement carries essentially all its
energy below ~10–20 Hz. 100 Hz was chosen with margin, so moderate loss costs
nothing measurable, while losing half the stream would. That is context for
interpreting the number, **not** a threshold — no cutoff is being set here.

## 4. Architecture

### 4.0 Repo layout

The iOS side gets its own space, with the shared library kept separable from the
shippable app:

```
ios/
  TrackingSystem.xcworkspace    the thing you open
  SensorCore/                   Swift package — builds and tests on macOS
    Sources/SensorCore/
      SensorPacket.swift        decode 16 bytes            exists, tested
      CaptureWriter.swift       CSV rows                   exists, unused until M3b
      LinkStats.swift           (seq, arrival) -> rate, loss   NEW
    Tests/SensorCoreTests/
  TrackingApp/                  Xcode app project — device only
    TrackingApp/
      BoardLink.swift           CoreBluetooth central; forwards (Data, arrival)
      BoardModel.swift          current state; publishes snapshots to the view
      LiveView.swift            SwiftUI, one panel per board
  README.md                     build, signing, and deploy notes
```

`SensorCore` stays a standalone package referenced as a local dependency rather than
being folded into the app target. That is what keeps `swift test` runnable on a Mac
with no phone attached — the property §4 depends on.

**Tooling note.** The `.xcodeproj` and `.xcworkspace` are Xcode-generated bundles
that cannot be authored reliably as text. Creating the app project and configuring
free-provisioning signing is a manual Xcode step in the implementation plan; every
Swift source file inside it is written normally.

**Module boundary (mirrors ADR-3).** `LinkStats` is pure arithmetic over sequence
numbers and arrival times and knows nothing about CoreBluetooth, exactly as
`sensor_stream.c` never calls `dwt_*`. This is not stylistic: the milestone's entire
output is a computed statistic, and a statistic verifiable only by holding two boards
and watching a number cannot be trusted. Separated, it is checked against synthetic
input on a Mac in milliseconds — and when the displayed loss looks wrong, the link
and the counter are independently falsifiable.

### 4.1 Finding and identifying the boards

Scan filtered by service UUID `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`, subscribe to
notify characteristic `6E40FE01-...`, and tell the two apart by advertised name —
the firmware already sets `DWM-INIT` / `DWM-RESP` by role (`sensor_ble.c:26-30`).

Degrade gracefully: whichever board is present connects and displays; the other panel
reads "searching". Auto-reconnect on drop.

### 4.2 Decoupling render rate from packet rate

Two boards at 100 Hz is ~200 delegate callbacks per second. Driving SwiftUI at that
rate would thrash the main thread and make the app itself a source of the loss it is
trying to measure. Packets update plain state as they arrive; a **10 Hz timer**
publishes a snapshot to the view. 10 Hz is already faster than a human reads a
changing number.

### 4.3 Counting loss honestly

- `seq` is `uint16` and wraps every 65536 packets — **655 s (~11 min) at 100 Hz**,
  well inside a session. Deltas are computed modulo 65536, so a wrap reads as a gap
  of 1, not a loss of 65,000.
- `expected` accumulates the sequence deltas; `received` counts packets;
  `loss = 1 − received/expected`.
- A backwards jump beyond the wrap window means the board **rebooted**. Start a
  fresh epoch rather than logging a nonsense figure.
- A disconnect ends the current epoch. Disconnects are counted and shown separately
  from packet loss — they are a different failure and must not be averaged into one.

## 5. Risks

- **Loss may be severe.** The likely causes are firmware-side: the SoftDevice's TX
  buffer filling (`sd_ble_gatts_hvx` returning `NRF_ERROR_RESOURCES`, currently
  unchecked) or the negotiated connection interval — iOS is expected to negotiate
  around 15 ms, which would not carry one notify per 10 ms tick without packing
  several per connection event. **This expectation is unverified**; M3a's job is to
  produce the evidence, not to act on it.
- **Free provisioning expires after 7 days.** Builds must be re-deployed from Xcode
  before any measurement session. Cheap, but a silent way to lose bench time.
- **Simulator cannot do this at all** — CoreBluetooth has no simulator support, so
  every device-level check needs the phone.

## 6. Verification

**`LinkStats` — unit tests on macOS**, covering the cases that are painful to
produce deliberately on hardware:

- clean run, no gaps → loss 0 %
- a single dropped packet → exactly one lost
- several separate gaps → sum correct
- the 65535 → 0 wrap → not counted as loss
- out-of-order arrival
- a board reset (`seq` jumps backwards) → new epoch, no nonsense figure

**Device test** — both boards powered, phone connected to both, foreground,
5-minute run:

- both panels show `connected`, with a plausible packets/sec and loss %
- accel values respond to moving each board, and the correct panel responds
- `uwb_mm` shows a real distance on `DWM-INIT` and stays blank on `DWM-RESP`
- rate and loss for both boards recorded in `docs/architecture.md`

## 7. Out of scope

- **Recording, CSV, export, background operation** — M3b
- **Plots and charting** — the accel signal is judged from exported CSV on a laptop,
  which is M4. A live trace is satisfying and answers nothing this milestone asks.
- **Any firmware change**, including reacting to the measured loss
- **NLOS rejection** — M2b.2, now sequenced after M3b (§2.1)
- **Phone-side fusion, pose estimation** — later phases

## 8. Self-review

- Goal and the one number it produces stated — §1 ✅
- Scope split with rationale, and the reordering ahead of M2b.2 justified — §2 ✅
- Criterion falsifiable, and the "no bar" choice's consequence made explicit
  rather than left implicit — §3 ✅
- Module boundary typed and justified on verifiability, not taste — §4 ✅
- `seq` wrap, reboot, and disconnect all specified rather than assumed — §4.3 ✅
- Risks named, with the unverified expectation labelled as unverified — §5 ✅
- Verification split into what is testable off-hardware and what needs the phone — §6 ✅
- No TBDs
