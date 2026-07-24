import Foundation
import Observation
import SensorCore

/// Live state for one board, published to the view at a fixed 10 Hz.
///
/// Packets land on the BLE queue at ~100 Hz and mutate `pending` under a lock.
/// A timer copies that into the observable properties on the main thread. The
/// radio rate and the render rate stay independent — and 10 Hz is already
/// faster than anyone reads a changing number.
@Observable
final class BoardModel {

    let role: BoardRole
    @ObservationIgnored private let recorder: RecordingController

    var state: LinkState = .starting
    var stats: LinkStats.Snapshot = LinkStats().snapshot
    var latest: SensorPacket?
    var disconnects: Int = 0

    @ObservationIgnored private var link: BoardLink?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var pendingStats = LinkStats()
    @ObservationIgnored private var pendingPacket: SensorPacket?
    @ObservationIgnored private var pendingState: LinkState = .starting
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    init(role: BoardRole, recorder: RecordingController) {
        self.role = role
        self.recorder = recorder
    }

    func start() {
        // onAppear can fire more than once for a scene root; a second call
        // would build a second BoardLink + timer, delivering every packet
        // twice. Duplicates hit the fwd==0 branch in LinkStats, which bumps
        // `received` without touching `expected` — loss would silently read
        // low and rate would read roughly double.
        guard !started else { return }
        started = true

        let link = BoardLink(
            role: role,
            onPacket: { [weak self] packet, arrival in
                guard let self else { return }
                self.recorder.append(role: self.role, packet: packet, arrival: arrival)
                self.lock.lock()
                self.pendingStats.record(seq: packet.seq, at: arrival)
                self.pendingPacket = packet
                self.lock.unlock()
            },
            onState: { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                // A board that stops streaming ends the current epoch, so
                // the firmware's seq — which keeps advancing while the link
                // is down — doesn't get charged to `expected` as loss when
                // the stream resumes far ahead on reconnect. Drop the last
                // packet too, so the view stops showing a stale accel and
                // distance as if the tag were still live.
                if state != .streaming && self.pendingState == .streaming {
                    self.pendingStats.endEpoch()
                    self.pendingPacket = nil
                }
                self.pendingState = state
                self.lock.unlock()
            })
        self.link = link
        link.start()

        // Scheduled explicitly on the main run loop (in .common mode) rather
        // than via Timer.scheduledTimer, which would bind to whatever
        // thread/run-loop-mode happens to be current when start() is called.
        // BoardModel has no UI caller yet, so that thread isn't guaranteed to
        // be main — and `publish()` mutates @Observable properties, which is
        // only safe on the main thread.
        let publishTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.publish()
        }
        RunLoop.main.add(publishTimer, forMode: .common)
        timer = publishTimer
    }

    private func publish() {
        lock.lock()
        let snapshot = pendingStats.snapshot
        let packet = pendingPacket
        let state = pendingState
        lock.unlock()

        self.stats = snapshot
        self.latest = packet
        self.state = state
        self.disconnects = link?.disconnectCount ?? 0
    }
}

/// Owns one model per board. Both run independently, so one missing tag
/// never blocks the other.
@Observable
final class AppModel {
    let recording = RecordingController()
    let boards: [BoardModel]

    @ObservationIgnored private var started = false

    init() {
        let recording = self.recording
        boards = BoardRole.allCases.map { BoardModel(role: $0, recorder: recording) }
    }

    func start() {
        // Guards against a repeated onAppear firing start() twice; each
        // BoardModel.start() is itself guarded too, but stopping here also
        // avoids re-iterating boards needlessly.
        guard !started else { return }
        started = true
        boards.forEach { $0.start() }
    }
}
