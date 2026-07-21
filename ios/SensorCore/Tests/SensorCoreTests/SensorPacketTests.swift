import XCTest
@testable import SensorCore

final class SensorPacketTests: XCTestCase {

    /// Builds a canonical 16-byte packet:
    /// seq=1, board_time_ms=2, ax=3, ay=-4, az=5, uwb_mm=1000 (all little-endian).
    private func canonicalData() -> Data {
        var d = Data()
        d.append(contentsOf: [0x01, 0x00])              // seq = 1
        d.append(contentsOf: [0x02, 0x00, 0x00, 0x00])  // board_time_ms = 2
        d.append(contentsOf: [0x03, 0x00])              // ax = 3
        d.append(contentsOf: [0xFC, 0xFF])              // ay = -4
        d.append(contentsOf: [0x05, 0x00])              // az = 5
        d.append(contentsOf: [0xE8, 0x03, 0x00, 0x00])  // uwb_mm = 1000
        return d
    }

    func test_decodesLittleEndianPacket() {
        let p = SensorPacket(canonicalData())
        XCTAssertEqual(p?.seq, 1)
        XCTAssertEqual(p?.boardTimeMs, 2)
        XCTAssertEqual(p?.ax, 3)
        XCTAssertEqual(p?.ay, -4)
        XCTAssertEqual(p?.az, 5)
        XCTAssertEqual(p?.uwbMm, 1000)
    }

    func test_responderSentinelBecomesNil() {
        // uwb_mm = 0xFFFFFFFF means "no distance" (responder board).
        let d = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNotNil(SensorPacket(d))
        XCTAssertNil(SensorPacket(d)?.uwbMm)
    }

    func test_wrongLengthReturnsNil() {
        XCTAssertNil(SensorPacket(Data([0, 1, 2])))
        XCTAssertNil(SensorPacket(Data(repeating: 0, count: 15)))
        XCTAssertNil(SensorPacket(Data(repeating: 0, count: 17)))
    }

    func test_maxUnsignedValuesDecodeCorrectly() {
        // seq = 0xFFFE (65534), board_time_ms = 0xFFFFFFFE, uwb = 65535 mm.
        var d = Data()
        d.append(contentsOf: [0xFE, 0xFF])              // seq
        d.append(contentsOf: [0xFE, 0xFF, 0xFF, 0xFF])  // board_time_ms
        d.append(contentsOf: [0x00, 0x00])              // ax
        d.append(contentsOf: [0x00, 0x00])              // ay
        d.append(contentsOf: [0x00, 0x00])              // az
        d.append(contentsOf: [0xFF, 0xFF, 0x00, 0x00])  // uwb = 65535
        let p = SensorPacket(d)
        XCTAssertEqual(p?.seq, 65534)
        XCTAssertEqual(p?.boardTimeMs, 4294967294)
        XCTAssertEqual(p?.uwbMm, 65535)
    }

    func test_accelGConvertsRawCountsToG() {
        // ax=16384, ay=-16384, az=0.
        var d = Data()
        d.append(contentsOf: [0x00, 0x00])              // seq
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // board_time_ms
        d.append(contentsOf: [0x00, 0x40])              // ax = 16384
        d.append(contentsOf: [0x00, 0xC0])              // ay = -16384
        d.append(contentsOf: [0x00, 0x00])              // az = 0
        d.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // uwb sentinel
        let p = SensorPacket(d)
        XCTAssertNotNil(p)
        let g = p!.accelG
        XCTAssertEqual(g.x, 1.0, accuracy: 1e-9, "16384 counts must be exactly 1 g")
        XCTAssertEqual(g.y, -1.0, accuracy: 1e-9, "a negative raw value must give the matching negative g")
        XCTAssertEqual(g.z, 0.0, accuracy: 1e-9)
    }
}
