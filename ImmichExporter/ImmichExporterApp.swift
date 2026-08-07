import SwiftUI

@main
struct ImmichExporterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 820)
    }
}
