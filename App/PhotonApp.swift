import PhotonShell
import SwiftUI

@main
struct PhotonApp: App {
    /// Opens a `.photon` (or legacy `.aether`) project double-clicked in the Finder.
    @NSApplicationDelegateAdaptor(PhotonAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Photon", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1180, minHeight: 820)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { PhotonCommands(model: model) }
    }
}
