import AetherShell
import SwiftUI

@main
struct AetherApp: App {
    /// Opens a `.aether` project double-clicked in the Finder.
    @NSApplicationDelegateAdaptor(AetherAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Aether", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1180, minHeight: 820)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AetherCommands(model: model) }
    }
}
