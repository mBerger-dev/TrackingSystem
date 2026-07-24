import SwiftUI

@main
struct TrackingAppApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground-only for now: finalize the file rather than record blind.
            if phase == .background { model.recording.stop() }
        }
    }
}
