import Foundation

/// Streams decoded packets to a CSV file, one row per packet.
///
/// Pure Foundation and handed a URL, so it is verified on a Mac against a temp
/// file rather than by holding two boards. Writes happen on a dedicated serial
/// queue, so appending never blocks the caller's thread (the BLE queues).
@available(macOS 10.15.4, iOS 13.4, *)
public final class CaptureSession {

    private let url: URL
    private let writer = CaptureWriter()
    private let queue = DispatchQueue(label: "capture.session.write")
    private var handle: FileHandle?
    private var closed = false
    private var _rowCount = 0
    private var _countsByBoard: [String: Int] = [:]

    public init(url: URL) { self.url = url }

    /// Creates the file and writes the CSV header exactly once.
    @available(macOS 10.15.4, iOS 13.4, *)
    public func start() throws {
        let header = writer.header() + "\n"
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
    }

    /// Enqueues one row. Non-blocking; ordering follows call order (FIFO queue).
    @available(macOS 10.15.4, iOS 13.4, *)
    public func append(board: String, phoneArrivalMs: Int64, packet: SensorPacket) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle, !self.closed else { return }
            let line = self.writer.row(board: board, phoneArrivalMs: phoneArrivalMs, packet) + "\n"
            do {
                try handle.write(contentsOf: Data(line.utf8))
                self._rowCount += 1
                self._countsByBoard[board, default: 0] += 1
            } catch {
                // Write failed (e.g. disk full). Best-effort recording: don't
                // crash, but don't count a row that isn't on disk either.
            }
        }
    }

    /// Flushes queued writes and closes the file. Safe to call more than once.
    @available(macOS 10.15.4, iOS 13.4, *)
    public func close() {
        queue.sync {
            guard !closed else { return }
            try? handle?.close()
            handle = nil
            closed = true
        }
    }

    public var rowCount: Int { queue.sync { _rowCount } }
    public var countsByBoard: [String: Int] { queue.sync { _countsByBoard } }
}
