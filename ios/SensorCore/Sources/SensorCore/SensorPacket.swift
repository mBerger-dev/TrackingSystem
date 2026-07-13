import Foundation

/// One decoded sensor sample from a board's BLE notify characteristic.
///
/// Wire format (little-endian, 16 bytes), frozen in `firmware/ble-contract.md`:
///   seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32
///
/// The initiator board reports a real `uwb_mm`; the responder sends the
/// sentinel `0xFFFFFFFF`, which decodes to `uwbMm == nil`.
public struct SensorPacket: Equatable {
    public let seq: UInt16
    public let boardTimeMs: UInt32
    public let ax: Int16
    public let ay: Int16
    public let az: Int16
    public let uwbMm: UInt32?

    /// Exact wire length; anything else is rejected.
    public static let byteCount = 16

    /// Sentinel meaning "this board has no distance" (the responder).
    public static let uwbSentinel: UInt32 = 0xFFFF_FFFF

    public init?(_ data: Data) {
        guard data.count == SensorPacket.byteCount else { return nil }
        // Copy into a zero-based array so a sliced Data (non-zero startIndex)
        // can't produce out-of-range indexing.
        let b = [UInt8](data)

        func u16(_ i: Int) -> UInt16 {
            UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
        }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i])
                | (UInt32(b[i + 1]) << 8)
                | (UInt32(b[i + 2]) << 16)
                | (UInt32(b[i + 3]) << 24)
        }

        self.seq = u16(0)
        self.boardTimeMs = u32(2)
        self.ax = Int16(bitPattern: u16(6))
        self.ay = Int16(bitPattern: u16(8))
        self.az = Int16(bitPattern: u16(10))

        let rawUwb = u32(12)
        self.uwbMm = (rawUwb == SensorPacket.uwbSentinel) ? nil : rawUwb
    }
}
