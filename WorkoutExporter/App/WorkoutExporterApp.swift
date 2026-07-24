import SwiftUI

@main
struct WorkoutExporterApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.settings)
        }
    }
}
