import XCTest
@testable import SensorCore

final class LinkStatsTests: XCTestCase {

    /// Feed a clean run of sequence numbers, one every 10 ms.
    private func feed(_ seqs: [UInt16], into stats: inout LinkStats, startAt t0: TimeInterval = 0) {
        for (i, s) in seqs.enumerated() {
            stats.record(seq: s, at: t0 + Double(i) * 0.01)
        }
    }

    func testCleanRunHasNoLoss() {
        var stats = LinkStats()
        feed([1, 2, 3, 4, 5], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.received, 5)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 0)
        XCTAssertEqual(s.lossFraction, 0.0, accuracy: 1e-9)
    }

    func testSingleGapCountsOneLost() {
        var stats = LinkStats()
        feed([1, 2, 4, 5], into: &stats)   // 3 never arrived
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 1)
        XCTAssertEqual(s.lossFraction, 0.2, accuracy: 1e-9)
    }

    func testSeveralGapsSumCorrectly() {
        var stats = LinkStats()
        feed([1, 3, 4, 9], into: &stats)   // lost 2, then 5,6,7,8 -> 5 total
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 9)
        XCTAssertEqual(s.lost, 5)
    }

    func testWrapAtUInt16BoundaryIsNotLoss() {
        var stats = LinkStats()
        feed([65534, 65535, 0, 1], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.received, 4)
        XCTAssertEqual(s.expected, 4)
        XCTAssertEqual(s.lost, 0, "65535 -> 0 is a step of one, not 65k lost packets")
        XCTAssertEqual(s.epochs, 1, "a wrap must not look like a reboot")
    }

    func testOutOfOrderArrivalIsNotCountedAsReboot() {
        var stats = LinkStats()
        feed([1, 2, 4, 3, 5], into: &stats)   // 3 arrives late
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 1)
        XCTAssertEqual(s.received, 5)
        XCTAssertEqual(s.expected, 5)
        XCTAssertEqual(s.lost, 0, "the late packet fills the gap it left")
    }

    func testDuplicateDoesNotAdvanceExpected() {
        var stats = LinkStats()
        feed([1, 2, 2, 3], into: &stats)
        let s = stats.snapshot
        XCTAssertEqual(s.expected, 3)
        XCTAssertEqual(s.received, 4)
    }

    func testBoardResetStartsNewEpoch() {
        var stats = LinkStats()
        feed([5000, 5001, 5002], into: &stats)
        stats.record(seq: 0, at: 0.10)        // board rebooted, seq restarts
        stats.record(seq: 1, at: 0.11)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 2)
        XCTAssertEqual(s.received, 2, "counters restart with the board")
        XCTAssertEqual(s.expected, 2)
        XCTAssertEqual(s.lost, 0, "a reboot must not be reported as 60k lost packets")
    }

    func testRateOverSlidingWindow() {
        var stats = LinkStats(rateWindow: 2.0)
        // 101 packets at exactly 10 ms spacing -> 100 Hz over 1.0 s
        for i in 0...100 {
            stats.record(seq: UInt16(i + 1), at: Double(i) * 0.01)
        }
        XCTAssertEqual(stats.snapshot.packetsPerSecond, 100.0, accuracy: 0.5)
    }

    func testRateIgnoresSamplesOlderThanWindow() {
        var stats = LinkStats(rateWindow: 1.0)
        stats.record(seq: 1, at: 0.0)         // ancient, must be pruned
        for i in 0...50 {
            stats.record(seq: UInt16(i + 2), at: 10.0 + Double(i) * 0.02)  // 50 Hz
        }
        XCTAssertEqual(stats.snapshot.packetsPerSecond, 50.0, accuracy: 1.0)
    }

    func testEmptyStatsAreZeroNotNaN() {
        let s = LinkStats().snapshot
        XCTAssertEqual(s.received, 0)
        XCTAssertEqual(s.expected, 0)
        XCTAssertEqual(s.lossFraction, 0.0)
        XCTAssertEqual(s.packetsPerSecond, 0.0)
        XCTAssertFalse(s.lossFraction.isNaN, "0/0 must not produce NaN")
    }

    func testBoundary_fwd_equals_32768_is_normal_forward_step() {
        var stats = LinkStats()
        stats.record(seq: 1, at: 0.0)
        // fwd = 32768 means 32767 packets lost + 1 received between seq 1 and 32769
        stats.record(seq: 32769, at: 0.01)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 1, "32768 is the inclusive top of the forward range")
        XCTAssertEqual(s.expected, 32769, "fwd==32768 advances expected by 32768")
        XCTAssertEqual(s.received, 2, "both packets arrived")
        XCTAssertEqual(s.lost, 32767, "32768-1 packets were skipped")
    }

    func testBoundary_fwd_equals_32769_is_reboot() {
        var stats = LinkStats()
        stats.record(seq: 1, at: 0.0)
        // fwd = 32769 exceeds forwardLimit, triggers reboot (not normal forward step)
        stats.record(seq: 32770, at: 0.01)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 2, "32769 exceeds forwardLimit and triggers reboot")
        XCTAssertEqual(s.received, 1, "snapshot shows only the reboot epoch")
        XCTAssertEqual(s.expected, 1, "reboot resets counter to 1")
    }

    func testBoundary_reorder_tolerance_exactly_64_is_late_arrival() {
        var stats = LinkStats()
        stats.record(seq: 1000, at: 0.0)
        // fwd = 65472 means 65536 - 65472 = 64 packets late (within tolerance)
        // This arrives out-of-order but within the reorder window
        stats.record(seq: 936, at: 0.01)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 1, "65536-fwd==64 is within reorderTolerance")
        XCTAssertEqual(s.expected, 1, "late arrival does not advance expected")
        XCTAssertEqual(s.received, 2, "late packet still counted as received")
        XCTAssertEqual(s.lost, 0, "late packet fills its gap")
    }

    func testBoundary_reorder_tolerance_exactly_65_is_reboot() {
        var stats = LinkStats()
        stats.record(seq: 1000, at: 0.0)
        // fwd = 65471 means 65536 - 65471 = 65 packets late (exceeds tolerance)
        stats.record(seq: 935, at: 0.01)
        let s = stats.snapshot
        XCTAssertEqual(s.epochs, 2, "65536-fwd==65 exceeds reorderTolerance, triggers reboot")
        XCTAssertEqual(s.received, 1, "snapshot shows only the reboot epoch")
        XCTAssertEqual(s.expected, 1, "reboot resets counter to 1")
    }
}
