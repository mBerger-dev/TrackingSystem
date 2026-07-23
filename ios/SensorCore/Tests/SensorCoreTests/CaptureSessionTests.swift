import XCTest
@testable import SensorCore

final class CaptureSessionTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
    }

    private func packet(seq: UInt16, boardTimeMs: UInt32 = 0,
                        ax: Int16 = 0, ay: Int16 = 0, az: Int16 = 0,
                        uwbMm: UInt32 = 0xFFFF_FFFF) -> SensorPacket {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
             UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        var b: [UInt8] = []
        b += le16(seq); b += le32(boardTimeMs)
        b += le16(UInt16(bitPattern: ax))
        b += le16(UInt16(bitPattern: ay))
        b += le16(UInt16(bitPattern: az))
        b += le32(uwbMm)
        return SensorPacket(Data(b))!
    }

    private func read(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testStartWritesHeaderOnceAndNoRows() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines, [CaptureWriter().header()])
        XCTAssertEqual(s.rowCount, 0)
    }

    func testAppendWritesOneRowPerPacket() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 0, packet: packet(seq: 1))
        s.append(board: "DWM-INIT", phoneArrivalMs: 10, packet: packet(seq: 2))
        s.append(board: "DWM-INIT", phoneArrivalMs: 20, packet: packet(seq: 3))
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines.count, 4, "header + 3 rows")
        XCTAssertEqual(s.rowCount, 3)
    }

    func testRowMatchesCaptureWriter() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        let p = packet(seq: 42, boardTimeMs: 1234, ax: -320, ay: 80, az: 16384, uwbMm: 1454)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 7, packet: p)
        s.close()
        let lines = read(url)
        XCTAssertEqual(lines[1],
            CaptureWriter().row(board: "DWM-INIT", phoneArrivalMs: 7, p))
    }

    func testBothBoardsInterleaveAndCount() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.append(board: "DWM-INIT", phoneArrivalMs: 0, packet: packet(seq: 1))
        s.append(board: "DWM-RESP", phoneArrivalMs: 1, packet: packet(seq: 5))
        s.append(board: "DWM-INIT", phoneArrivalMs: 2, packet: packet(seq: 2))
        s.close()
        let lines = read(url)
        XCTAssertTrue(lines[1].hasPrefix("DWM-INIT,"))
        XCTAssertTrue(lines[2].hasPrefix("DWM-RESP,"))
        XCTAssertTrue(lines[3].hasPrefix("DWM-INIT,"))
        XCTAssertEqual(s.countsByBoard, ["DWM-INIT": 2, "DWM-RESP": 1])
    }

    func testCloseIsIdempotent() throws {
        let url = tempURL()
        let s = CaptureSession(url: url)
        try s.start()
        s.close()
        s.close()   // must not crash
        XCTAssertEqual(read(url), [CaptureWriter().header()])
    }
}
