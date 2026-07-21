import SwiftUI
import SensorCore

struct LiveView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List(model.boards, id: \.role) { board in
                BoardPanel(board: board)
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
                Text(board.state).foregroundStyle(.secondary)
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

    /// Raw counts are left-justified 12-bit at +-2 g: 16384 counts per g.
    private var accelText: String {
        guard let p = board.latest else { return "—" }
        let g = { (raw: Int16) in Double(raw) / 16384.0 }
        return String(format: "%+.2f  %+.2f  %+.2f g", g(p.ax), g(p.ay), g(p.az))
    }

    private var distText: String {
        guard let p = board.latest else { return "—" }
        guard let mm = p.uwbMm else { return "—" }
        return "\(mm) mm"
    }
}
