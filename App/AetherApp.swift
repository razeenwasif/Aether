import AetherShell
import SwiftUI

@main
struct AetherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Aether", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1180, minHeight: 820)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AetherCommands(model: model) }
    }
}
