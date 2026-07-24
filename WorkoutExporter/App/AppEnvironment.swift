import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    var healthClient: any HealthKitClient
    let settings: UserSettings
    let packageBuilder: any ExportPackageBuilding
    var isUsingSyntheticData = false

    init() {
        healthClient = LiveHealthKitClient()
        settings = UserSettings()
        packageBuilder = ExportPackageBuilder()
        cleanupExpiredExports()
    }

    #if DEBUG
    func useSyntheticData() {
        healthClient = SyntheticHealthKitClient()
        isUsingSyntheticData = true
    }

    func useLiveData() {
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
