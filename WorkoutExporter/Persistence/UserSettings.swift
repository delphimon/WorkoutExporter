import Foundation
import Observation

@MainActor
@Observable
final class UserSettings {
    var distanceUnits: DistanceUnitPreference {
        didSet { defaults.set(distanceUnits.rawValue, forKey: Keys.distanceUnits) }
    }
    var metricSettings: MetricCalculationSettings
    var includeRawSamples: Bool
    var includeSourceMetadata: Bool
    var packageAsZIP: Bool
    var defaultFormats: Set<ExportFormat>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        distanceUnits = DistanceUnitPreference(rawValue: defaults.string(forKey: Keys.distanceUnits) ?? "") ?? .metric
        includeRawSamples = defaults.object(forKey: Keys.includeRawSamples) as? Bool ?? true
        includeSourceMetadata = defaults.object(forKey: Keys.includeSourceMetadata) as? Bool ?? true
        packageAsZIP = defaults.object(forKey: Keys.packageAsZIP) as? Bool ?? true
        defaultFormats = [.json, .csv, .gpx, .tcx]
        metricSettings = .conservativeDefault
    }

    func persistBooleans() {
        defaults.set(includeRawSamples, forKey: Keys.includeRawSamples)
        defaults.set(includeSourceMetadata, forKey: Keys.includeSourceMetadata)
        defaults.set(packageAsZIP, forKey: Keys.packageAsZIP)
    }

    private enum Keys {
        static let distanceUnits = "distanceUnits"
        static let includeRawSamples = "includeRawSamples"
        static let includeSourceMetadata = "includeSourceMetadata"
        static let packageAsZIP = "packageAsZIP"
    }
}
