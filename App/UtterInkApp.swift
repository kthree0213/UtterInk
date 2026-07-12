import SwiftUI
import UtterInkCore

@main
struct UtterInkApp: App {
    var body: some Scene {
        MenuBarExtra(ProductIdentity.name, systemImage: "text.cursor") {
            Text("UtterInk foundation ready")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }

        Settings {
            Text("UtterInk Settings")
                .padding(24)
        }
    }
}
