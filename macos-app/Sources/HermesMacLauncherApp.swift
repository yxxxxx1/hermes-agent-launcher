import SwiftUI

@main
struct HermesMacLauncherApp: App {
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup {
            LauncherRootView(store: store)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 760)
        Settings {
            EmptyView()
        }
    }
}
