import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    var healthClient: any HealthKitClient
    let settings: UserSettings
    var packageBuilder: any ExportPackageBuilding
    let routePresentationStore = WorkoutRoutePresentationStore()
    var isUsingSyntheticData = false

    init() {
        healthClient = LiveHealthKitClient()
        settings = UserSettings()
        packageBuilder = ExportPackageBuilder()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing")
            || arguments.contains("--ui-testing-onboarding")
            || arguments.contains("--ui-testing-export-error") {
            healthClient = SyntheticHealthKitClient()
            isUsingSyntheticData = true
            UserDefaults.standard.set(
                !arguments.contains("--ui-testing-onboarding"),
                forKey: "authorizationRequestCompleted"
            )
        }
        if arguments.contains("--ui-testing-export-error") {
            packageBuilder = UITestFailingPackageBuilder()
        }
        #endif
        cleanupExpiredExports()
    }

    #if DEBUG
    func useSyntheticData() {
        routePresentationStore.reset()
        healthClient = SyntheticHealthKitClient()
        isUsingSyntheticData = true
    }

    func useLiveData() {
        routePresentationStore.reset()
        healthClient = LiveHealthKitClient()
        isUsingSyntheticData = false
    }
    #endif

    var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "WorkoutExporterExports", directoryHint: .isDirectory)
    }

    private func cleanupExpiredExports() {
        let directory = exportDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let expiration = Date().addingTimeInterval(-86_400)
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < expiration }) ?? false {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

#if DEBUG
private actor UITestFailingPackageBuilder: ExportPackageBuilding {
    func buildPackage(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> URL {
        throw WorkoutExporterError.fileWriteFailure("UI test export failure")
    }
}
#endif
