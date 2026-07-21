import SwiftUI

@main
struct TrackingAppApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
    }
}
