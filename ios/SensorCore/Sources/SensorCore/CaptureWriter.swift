import Foundation

/// Formats decoded packets into CSV rows for a recorded capture.
///
/// Column order is frozen (shared with any downstream analysis):
///   board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm
///
/// `uwb_mm` is left empty for responder samples (no distance).
public struct CaptureWriter {
    public init() {}

    public func header() -> String {
        "board,seq,board_time_ms,phone_arrival_ms,ax,ay,az,uwb_mm"
    }

    public func row(board: String, phoneArrivalMs: Int64, _ p: SensorPacket) -> String {
        let uwb = p.uwbMm.map(String.init) ?? ""
        return "\(board),\(p.seq),\(p.boardTimeMs),\(phoneArrivalMs),\(p.ax),\(p.ay),\(p.az),\(uwb)"
    }
}
