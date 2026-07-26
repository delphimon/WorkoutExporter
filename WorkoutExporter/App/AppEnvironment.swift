import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    var healthClient: any HealthKitClient
    let settings: UserSettings
    var packageBuilder: any ExportPackageBuilding
    let routePresentationStore = WorkoutRoutePresentationStore()
    let workoutMetadataStore: WorkoutMetadataStore
    let exportDirectory: URL
    var isUsingSyntheticData = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains { $0.hasPrefix("--ui-testing") }
        exportDirectory = FileManager.default.temporaryDirectory.appending(
            path: "WorkoutExporterExports",
            directoryHint: .isDirectory
        )
        if isUITesting {
            try? FileManager.default.removeItem(at: exportDirectory)
        } else {
            Self.cleanupExpiredExports(in: exportDirectory)
        }
        let metadataURL: URL? = if isUITesting {
            FileManager.default.temporaryDirectory
                .appending(path: "WorkoutExporterUITestMetadata", directoryHint: .isDirectory)
                .appending(path: "workout-metadata.json")
        } else {
            nil
        }
        if let metadataURL {
            try? FileManager.default.removeItem(
                at: metadataURL.deletingLastPathComponent()
            )
        }
        workoutMetadataStore = WorkoutMetadataStore(
            persistenceURL: metadataURL,
            exportDirectory: exportDirectory
        )
        healthClient = LiveHealthKitClient()
        settings = UserSettings()
        packageBuilder = ExportPackageBuilder()
        #if DEBUG
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

    private static func cleanupExpiredExports(in directory: URL) {
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
    func buildPackageResult(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> ExportPackageResult {
        throw WorkoutExporterError.fileWriteFailure("UI test export failure")
    }
}
#endif
