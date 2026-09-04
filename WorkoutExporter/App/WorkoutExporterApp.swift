import SwiftUI

@main
struct WorkoutExporterApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            PrivacyProtectedRootView()
                .environment(environment)
                .environment(environment.settings)
        }
    }
}

private struct PrivacyProtectedRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .privacySensitive()
            .overlay {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay {
                        Label("Activity Manager", systemImage: "lock.shield")
                            .font(.headline)
                    }
                    .opacity(scenePhase == .active ? 0 : 1)
                    .allowsHitTesting(scenePhase != .active)
                    .accessibilityHidden(scenePhase == .active)
            }
    }
}
