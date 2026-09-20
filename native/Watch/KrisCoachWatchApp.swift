import SwiftUI

@main
struct KrisCoachWatchApp: App {
    @State private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environment(model)
        }
    }
}
