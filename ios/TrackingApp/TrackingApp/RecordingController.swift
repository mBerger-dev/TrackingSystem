import Foundation
import Observation
import SensorCore

/// A finished recording on disk.
struct RecordedSession: Identifiable {
    let id: URL
    let name: String
    let rowCount: Int
    var url: URL { id }
}

/// Owns the active recording and the list of finished ones. Device-specific
/// (Documents directory, share); the CSV writing lives in `CaptureSession`.
@Observable
final class RecordingController {

    var isRecording = false
    var label = "session"
    var elapsed: TimeInterval = 0
    var totalRows = 0
    var countsByBoard: [String: Int] = [:]
    var sessions: [RecordedSession] = []

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var startUptime: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?

    init() { refreshSessions() }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard !isRecording else { return }
        let url = documentsURL.appendingPathComponent(Self.fileName(label: label))
        let session = CaptureSession(url: url)
        do { try session.start() } catch { return }

        lock.lock()
        self.session = session
        self.startUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        isRecording = true
        elapsed = 0
        totalRows = 0
        countsByBoard = [:]

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from the BLE queues at ~100 Hz per board. No-op unless recording.
    func append(role: BoardRole, packet: SensorPacket, arrival: TimeInterval) {
        lock.lock()
        let session = self.session
        let start = self.startUptime
        lock.unlock()
        guard let session else { return }
        let ms = Int64((arrival - start) * 1000)
        session.append(board: role.rawValue, phoneArrivalMs: ms, packet: packet)
    }

    func stop() {
        guard isRecording else { return }
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.close()
        timer?.invalidate()
        timer = nil
        isRecording = false
        refreshSessions()
    }

    func delete(_ session: RecordedSession) {
        try? FileManager.default.removeItem(at: session.url)
        refreshSessions()
    }

    private func tick() {
        lock.lock()
        let session = self.session
        let start = self.startUptime
        lock.unlock()
        guard let session else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - start
        totalRows = session.rowCount
        countsByBoard = session.countsByBoard
    }

    private func refreshSessions() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let csvs = urls.filter { $0.pathExtension == "csv" }
        let sorted = csvs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
        sessions = sorted.map {
            RecordedSession(id: $0, name: $0.lastPathComponent, rowCount: Self.countRows($0))
        }
    }

    private static func countRows(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return max(0, lines.count - 1)   // minus the header
    }

    private static func fileName(label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.map { "/: ".contains($0) ? "-" : $0 }
        let base = cleaned.isEmpty ? "session" : String(cleaned)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(base)-\(fmt.string(from: Date())).csv"
    }
}
