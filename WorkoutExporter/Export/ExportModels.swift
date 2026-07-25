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

struct ExportProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case preparing
        case json
        case csv
        case gpx
        case tcx
        case manifest
        case archiving
        case finalizing
    }

    var phase: Phase
    var completedWorkouts: Int
    var totalWorkouts: Int

    var message: String {
        let action = switch phase {
        case .preparing: "Preparing workout data"
        case .json: "Writing JSON"
        case .csv: "Writing CSV files"
        case .gpx: "Writing GPX route"
        case .tcx: "Writing TCX workout"
        case .manifest: "Calculating file checksums"
        case .archiving: "Creating ZIP archive"
        case .finalizing: "Finalizing export"
        }
        guard totalWorkouts > 1 else { return action }
        return "\(action) · workout \(min(completedWorkouts + 1, totalWorkouts)) of \(totalWorkouts)"
    }
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
