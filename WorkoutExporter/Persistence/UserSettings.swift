import Foundation
import Observation

@MainActor
@Observable
final class UserSettings {
    var distanceUnits: DistanceUnitPreference {
        didSet {
            defaults.set(distanceUnits.rawValue, forKey: Keys.distanceUnits)
            metricSettings.splitDistanceMeters =
                distanceUnits.normalizingLegacySplitDistance(
                    metricSettings.splitDistanceMeters
                )
        }
    }
    var metricSettings: MetricCalculationSettings
    var filenameFormat: ExportFilenameFormat
    var includeRawSamples: Bool
    var includeSourceMetadata: Bool
    var packageAsZIP: Bool
    var defaultFormats: Set<ExportFormat>
    var defaultExportPreset: ExportPreset

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        distanceUnits = DistanceUnitPreference(rawValue: defaults.string(forKey: Keys.distanceUnits) ?? "") ?? .metric
        filenameFormat = ExportFilenameFormat(
            rawValue: defaults.string(forKey: Keys.filenameFormat) ?? ""
        ) ?? .dateActivityIdentifier
        includeRawSamples = defaults.object(forKey: Keys.includeRawSamples) as? Bool ?? true
        includeSourceMetadata = defaults.object(forKey: Keys.includeSourceMetadata) as? Bool ?? true
        packageAsZIP = defaults.object(forKey: Keys.packageAsZIP) as? Bool ?? true
        defaultExportPreset = ExportPreset(
            rawValue: defaults.string(forKey: Keys.defaultExportPreset) ?? ""
        ) ?? .basic
        if let data = defaults.data(forKey: Keys.defaultFormats),
           let formats = try? JSONDecoder().decode(Set<ExportFormat>.self, from: data) {
            defaultFormats = formats
        } else {
            defaultFormats = [.json, .gpx]
        }
        if let data = defaults.data(forKey: Keys.metricSettings),
           let decoded = try? JSONDecoder().decode(MetricCalculationSettings.self, from: data) {
            metricSettings = decoded
        } else {
            metricSettings = .conservativeDefault
        }
        metricSettings.splitDistanceMeters =
            distanceUnits.normalizingLegacySplitDistance(
                metricSettings.splitDistanceMeters
            )
    }

    func persist() {
        defaults.set(filenameFormat.rawValue, forKey: Keys.filenameFormat)
        defaults.set(includeRawSamples, forKey: Keys.includeRawSamples)
        defaults.set(includeSourceMetadata, forKey: Keys.includeSourceMetadata)
        defaults.set(packageAsZIP, forKey: Keys.packageAsZIP)
        defaults.set(try? JSONEncoder().encode(defaultFormats), forKey: Keys.defaultFormats)
        defaults.set(defaultExportPreset.rawValue, forKey: Keys.defaultExportPreset)
        defaults.set(try? JSONEncoder().encode(metricSettings), forKey: Keys.metricSettings)
    }

    private enum Keys {
        static let distanceUnits = "distanceUnits"
        static let filenameFormat = "filenameFormat"
        static let includeRawSamples = "includeRawSamples"
        static let includeSourceMetadata = "includeSourceMetadata"
        static let packageAsZIP = "packageAsZIP"
        static let defaultFormats = "defaultFormats"
        static let defaultExportPreset = "defaultExportPreset"
        static let metricSettings = "metricSettings"
    }
}
