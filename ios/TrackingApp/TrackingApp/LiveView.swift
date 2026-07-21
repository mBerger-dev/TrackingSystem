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

    private var accelText: String {
        guard let p = board.latest else { return "—" }
        let g = p.accelG
        // Adding +0.0 normalises negative zero (e.g. -0.001 rounded to 2
        // places would otherwise print "-0.00"), so tiny negative values
        // that round to zero don't render a misleading minus sign.
        return String(format: "%+.2f  %+.2f  %+.2f g", g.x + 0.0, g.y + 0.0, g.z + 0.0)
    }

    private var distText: String {
        guard let p = board.latest else { return "—" }
        guard let mm = p.uwbMm else { return "—" }
        return "\(mm) mm"
    }
}
