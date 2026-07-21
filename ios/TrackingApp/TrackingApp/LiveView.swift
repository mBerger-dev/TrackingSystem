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
