import XCTest
@testable import SensorCore

final class CaptureWriterTests: XCTestCase {

    private func packet(uwbSentinel: Bool) -> SensorPacket {
        // seq=1, time=2, ax=3, ay=-4, az=5, uwb=1000 (or 0xFFFFFFFF sentinel).
        let uwb: [UInt8] = uwbSentinel ? [0xFF, 0xFF, 0xFF, 0xFF] : [0xE8, 0x03, 0x00, 0x00]
        var d = Data([0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0xFC, 0xFF, 0x05, 0x00])
        d.append(contentsOf: uwb)
        return SensorPacket(d)!
    }

    func test_headerColumns() {
        XCTAssertEqual(
            CaptureWriter().header(),
            "board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm"
        )
    }

    func test_initiatorRowFormatting() {
        let row = CaptureWriter().row(board: "INIT", phoneArrivalMs: 999, packet(uwbSentinel: false))
        XCTAssertEqual(row, "INIT,1,2,999,3,-4,5,1000")
    }

    func test_responderRowLeavesUwbBlank() {
        let row = CaptureWriter().row(board: "RESP", phoneArrivalMs: 5, packet(uwbSentinel: true))
        XCTAssertEqual(row, "RESP,1,2,5,3,-4,5,")
    }
}
