import SwiftUI
import SensorCore

struct LiveView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                RecordBar(rec: model.recording)
                ForEach(model.boards, id: \.role) { board in
                    BoardPanel(board: board)
                }
                SessionsSection(rec: model.recording)
            }
            .navigationTitle("Tags")
        }
    }
}

private struct BoardPanel: View {
    let board: BoardModel

    var body: some View {
        Section {
            row("rate", String(format: "%.1f /s", board.stats.packetsPerSecond))
            row("loss", String(format: "%.2f %%  (%d of %d)",
                               board.stats.lossFraction * 100,
                               board.stats.lost,
                               board.stats.expected))
            row("accel", accelText)
            row("dist", distText)
            if board.disconnects > 0 {
                row("drops", "\(board.disconnects)")
            }
        } header: {
            HStack {
                Text(board.role.rawValue)
                Spacer()
                Text(board.state.label).foregroundStyle(.secondary)
            }
            .font(.headline)
            .textCase(nil)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    /// Round to the displayed precision first, so a tiny negative reading
    /// (raw -1 is -0.00006 g) prints "+0.00" rather than a misleading "-0.00".
    /// Rounding has to happen before formatting — %.2f alone keeps the sign.
    private func gText(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        return String(format: "%+.2f", rounded == 0 ? 0 : rounded)
    }

    private var accelText: String {
        guard let p = board.latest else { return "—" }
        let g = p.accelG
        return "\(gText(g.x))  \(gText(g.y))  \(gText(g.z)) g"
    }

    private var distText: String {
        guard let p = board.latest else { return "—" }
        guard let mm = p.uwbMm else { return "—" }
        return "\(mm) mm"
    }
}

private struct RecordBar: View {
    @Bindable var rec: RecordingController

    var body: some View {
        Section {
            if rec.isRecording {
                HStack {
                    Label(rec.label, systemImage: "record.circle")
                        .foregroundStyle(.red)
                    Spacer()
                    Text(Self.time(rec.elapsed)).monospacedDigit()
                    Button("Stop", role: .destructive) { rec.stop() }
                        .buttonStyle(.borderedProminent)
                }
                Text(rowSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                HStack {
                    TextField("label", text: $rec.label)
                        .textInputAutocapitalization(.never)
                    Button("Start") { rec.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var rowSummary: String {
        let init_ = rec.countsByBoard["DWM-INIT"] ?? 0
        let resp = rec.countsByBoard["DWM-RESP"] ?? 0
        return "\(rec.totalRows) rows  ·  INIT \(init_) / RESP \(resp)"
    }

    private static func time(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct SessionsSection: View {
    let rec: RecordingController

    var body: some View {
        if !rec.sessions.isEmpty {
            Section("Sessions") {
                ForEach(rec.sessions) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.subheadline)
                            Text("\(s.rowCount) rows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: s.url)
                    }
                }
                .onDelete { offsets in
                    offsets.map { rec.sessions[$0] }.forEach(rec.delete)
                }
            }
        }
    }
}
