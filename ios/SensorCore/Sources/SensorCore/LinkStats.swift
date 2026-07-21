import Foundation

/// Measures how much of a board's packet stream actually arrives.
///
/// Fed `(seq, arrivalTime)` pairs, it reports packet rate and loss. It knows
/// nothing about Bluetooth so it can be verified on a Mac against synthetic
/// input — which matters, because a loss figure you can only check by holding
/// two boards and squinting is not evidence.
///
/// `seq` is a `UInt16` that wraps every 65536 packets (~11 min at 100 Hz), so
/// all deltas are computed with wrapping arithmetic.
public struct LinkStats {

    public struct Snapshot: Equatable {
        public let received: Int
        public let expected: Int
        public let lost: Int
        public let lossFraction: Double
        public let packetsPerSecond: Double
        /// Increments when the board reboots (`seq` jumps backwards a long way).
        public let epochs: Int
    }

    /// A backwards jump of at most this many is late delivery, not a reboot.
    private static let reorderTolerance = 64
    /// Above this, a forward delta is really a backwards jump modulo 65536.
    private static let forwardLimit = 32768

    private let rateWindow: TimeInterval
    private var lastSeq: UInt16?
    private var received = 0
    private var expected = 0
    private var epochs = 0
    private var arrivals: [TimeInterval] = []

    public init(rateWindow: TimeInterval = 2.0) {
        self.rateWindow = rateWindow
    }

    public mutating func record(seq: UInt16, at time: TimeInterval) {
        defer { noteArrival(at: time) }

        guard let last = lastSeq else {
            startEpoch(at: seq)
            return
        }

        let fwd = Int(seq &- last)

        if fwd == 0 {
            received += 1                     // duplicate
        } else if fwd <= Self.forwardLimit {
            expected += fwd                   // normal step; fwd-1 were lost
            received += 1
            lastSeq = seq
        } else if 65536 - fwd <= Self.reorderTolerance {
            received += 1                     // arrived late, fills its own gap
        } else {
            arrivals.removeAll()              // board rebooted
            startEpoch(at: seq)
        }
    }

    public var snapshot: Snapshot {
        let lost = max(0, expected - received)
        return Snapshot(
            received: received,
            expected: expected,
            lost: lost,
            lossFraction: expected > 0 ? Double(lost) / Double(expected) : 0,
            packetsPerSecond: rate,
            epochs: epochs
        )
    }

    private mutating func startEpoch(at seq: UInt16) {
        lastSeq = seq
        received = 1
        expected = 1
        epochs += 1
    }

    private mutating func noteArrival(at time: TimeInterval) {
        arrivals.append(time)
        let cutoff = time - rateWindow
        if let keepFrom = arrivals.firstIndex(where: { $0 >= cutoff }), keepFrom > 0 {
            arrivals.removeFirst(keepFrom)
        }
    }

    private var rate: Double {
        guard let first = arrivals.first, let lastTime = arrivals.last,
              arrivals.count >= 2, lastTime > first else { return 0 }
        return Double(arrivals.count - 1) / (lastTime - first)
    }
}
