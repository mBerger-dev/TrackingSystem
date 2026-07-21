import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        LiveView(model: model)
    }
}
