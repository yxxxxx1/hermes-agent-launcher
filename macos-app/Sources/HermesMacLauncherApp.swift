import SwiftUI

@main
struct HermesMacLauncherApp: App {
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup {
            LauncherRootView(store: store)
                .frame(width: 720, height: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)
        Settings {
            EmptyView()
        }
    }
}
