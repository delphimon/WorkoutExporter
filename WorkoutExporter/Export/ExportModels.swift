import Foundation

enum ExportFormat: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case json
    case csv
    case gpx
    case tcx

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

struct ExportOptions: Codable, Hashable, Sendable {
    var formats: Set<ExportFormat> = Set(ExportFormat.allCases)
    var units: DistanceUnitPreference = .metric
    var includeRawSamples = true
    var includeDerivedMetrics = true
    var includeHeartRate = true
    var includeRoute = true
    var includeSourceAndDevice = true
    var movingTimeMethod: MovingTimeMethod = .eventAware
    var packageAsZIP = true
}

struct ExportFileEntry: Codable, Hashable, Sendable {
    var path: String
    var contentType: String
    var byteSize: Int
    var sha256: String
}

struct ExportManifest: Codable, Hashable, Sendable {
    var schemaName = "com.delphimon.workout-export-package"
    var schemaVersion = "1.0.0"
    var createdAt: Date
    var exporterVersion: String
    var files: [ExportFileEntry]
    var warnings: [String]
}

struct WorkoutExportEnvelope: Codable, Hashable, Sendable {
    var schemaName = "com.delphimon.workout-export"
    var schemaVersion = "1.0.0"
    var exporterVersion: String
    var exportedAt: Date
    var timeZoneIdentifier: String
    var workout: WorkoutDetail
}
