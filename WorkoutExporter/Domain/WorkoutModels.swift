import Foundation

enum DataProvenance: String, Codable, Sendable {
    case healthKitSample
    case healthKitStatistic
    case location
    case routeDerived
    case smoothedRouteDerived
    case userConfigured
}

struct SourceInfo: Codable, Hashable, Sendable {
    var name: String
    var bundleIdentifier: String
    var version: String?
    var operatingSystemVersion: String?
}

struct DeviceInfo: Codable, Hashable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var hardwareVersion: String?
    var softwareVersion: String?
    var localIdentifier: String?
    var firmwareVersion: String?
}

struct WorkoutSummary: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var activityIdentifier: UInt
    var activityName: String
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var totalDistanceMeters: Double?
    var activeEnergyKilocalories: Double?
    var averageHeartRateBPM: Double?
    var source: SourceInfo
    var device: DeviceInfo?
    var hasRoute: Bool
    var hasDetailedSamples: Bool
}

struct WorkoutSample: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var typeIdentifier: String
    var startDate: Date
    var endDate: Date
    var value: Double
    var unit: String
    var source: SourceInfo
    var device: DeviceInfo?
    var provenance: DataProvenance
    var metadata: [String: String]
}

struct CategorySample: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var typeIdentifier: String
    var startDate: Date
    var endDate: Date
    var value: Int
    var source: SourceInfo
    var metadata: [String: String]
}

struct RoutePoint: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var routeID: UUID
    var sequence: Int
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double
    var ellipsoidalAltitudeMeters: Double?
    var horizontalAccuracyMeters: Double
    var verticalAccuracyMeters: Double
    var speedMetersPerSecond: Double?
    var speedAccuracyMetersPerSecond: Double?
    var courseDegrees: Double?
    var courseAccuracyDegrees: Double?
    var floor: Int?
    var qualityFlags: [String]
}

enum WorkoutEventKind: String, Codable, Sendable {
    case pause
    case resume
    case lap
    case segment
    case marker
    case unknown
}

struct WorkoutEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: WorkoutEventKind
    var startDate: Date
    var endDate: Date?
    var metadata: [String: String]
}

struct WorkoutActivitySegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var activityIdentifier: UInt
    var activityName: String
    var startDate: Date
    var endDate: Date
    var metadata: [String: String]
}

struct NativeStatistic: Identifiable, Codable, Hashable, Sendable {
    var id: String { typeIdentifier + ":" + aggregation }
    var typeIdentifier: String
    var aggregation: String
    var value: Double
    var unit: String
}

enum MovingTimeMethod: String, Codable, CaseIterable, Sendable {
    case eventAware
    case speedThreshold
}

struct MetricCalculationSettings: Codable, Hashable, Sendable {
    var movingSpeedThresholdMetersPerSecond = 0.75
    var minimumMovingDuration: TimeInterval = 3
    var minimumStoppedDuration: TimeInterval = 5
    var maximumHorizontalAccuracyMeters = 50.0
    var maximumRouteGap: TimeInterval = 30
    var maximumPlausibleSpeedMetersPerSecond = 30.0
    var speedSmoothingWindow = 5
    var elevationSmoothingWindow = 7
    var elevationNoiseThresholdMeters = 3.0
    var splitDistanceMeters = 1_000.0

    static let conservativeDefault = MetricCalculationSettings()
}

struct MetricValue: Codable, Hashable, Sendable {
    var value: Double
    var unit: String
    var provenance: DataProvenance
}

struct WorkoutSplit: Identifiable, Codable, Hashable, Sendable {
    var id: Int { index }
    var index: Int
    var startDate: Date
    var endDate: Date
    var distanceMeters: Double
    var elapsedTime: TimeInterval
    var movingTime: TimeInterval
    var paceSecondsPerKilometer: Double?
    var speedMetersPerSecond: Double?
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var averageHeartRateBPM: Double?
    var maximumHeartRateBPM: Double?
    var startLatitude: Double?
    var startLongitude: Double?
    var endLatitude: Double?
    var endLongitude: Double?
}

struct DerivedMetrics: Codable, Hashable, Sendable {
    var routeDistanceMeters: MetricValue? = nil
    var eventAwareMovingTime: MetricValue? = nil
    var speedThresholdMovingTime: MetricValue? = nil
    var averageSpeedMetersPerSecond: MetricValue? = nil
    var maximumSpeedMetersPerSecond: MetricValue? = nil
    var rawElevationGainMeters: MetricValue? = nil
    var smoothedElevationGainMeters: MetricValue? = nil
    var elevationLossMeters: MetricValue? = nil
    var minimumAltitudeMeters: MetricValue? = nil
    var maximumAltitudeMeters: MetricValue? = nil
    var averageHeartRateBPM: MetricValue? = nil
    var minimumHeartRateBPM: MetricValue? = nil
    var maximumHeartRateBPM: MetricValue? = nil
    var splits: [WorkoutSplit] = []
    var warnings: [String] = []

    static let empty = DerivedMetrics(splits: [], warnings: [])
}

struct WorkoutDetail: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { summary.id }
    var summary: WorkoutSummary
    var events: [WorkoutEvent]
    var activities: [WorkoutActivitySegment]
    var statistics: [NativeStatistic]
    var samples: [WorkoutSample]
    var categorySamples: [CategorySample]
    var routes: [UUID: [RoutePoint]]
    var metadata: [String: String]
    var derived: DerivedMetrics
    var metricSettings: MetricCalculationSettings
    var warnings: [String]

    var routePoints: [RoutePoint] {
        routes.values.flatMap { $0 }.sorted {
            if $0.timestamp == $1.timestamp {
                if $0.routeID == $1.routeID { return $0.sequence < $1.sequence }
                return $0.routeID.uuidString < $1.routeID.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
    }

    var heartRateSamples: [WorkoutSample] {
        samples.filter { $0.typeIdentifier == "HKQuantityTypeIdentifierHeartRate" }
    }
}

enum WorkoutExporterError: LocalizedError, Equatable, Sendable {
    case healthKitUnavailable
    case authorizationNotRequested
    case noAccessibleData
    case queryFailure(String)
    case routeUnavailable
    case routeQueryFailure(String)
    case inconsistentSample(String)
    case metricWarning(String)
    case encodingFailure(String)
    case zipCreationFailure(String)
    case fileWriteFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable: "Health data is not available on this device."
        case .authorizationNotRequested: "Health access has not been requested."
        case .noAccessibleData: "No accessible workouts were found. HealthKit does not reveal whether read access was denied."
        case .queryFailure(let detail): "Health data query failed: \(detail)"
        case .routeUnavailable: "This workout has no accessible route."
        case .routeQueryFailure(let detail): "Route query failed: \(detail)"
        case .inconsistentSample(let detail): "A sample was inconsistent: \(detail)"
        case .metricWarning(let detail): "A metric could not be calculated reliably: \(detail)"
        case .encodingFailure(let detail): "Export encoding failed: \(detail)"
        case .zipCreationFailure(let detail): "ZIP package creation failed: \(detail)"
        case .fileWriteFailure(let detail): "Export file could not be written: \(detail)"
        case .cancelled: "Export cancelled."
        }
    }
}
