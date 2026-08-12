import Foundation

enum ExportSchema {
    static let version = "1.2.0"
}

enum ExportPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic
    case detailed
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: "Basic"
        case .detailed: "Detailed Analysis"
        case .custom: "Custom"
        }
    }

    var description: String {
        switch self {
        case .basic:
            "One spreadsheet-ready CSV with recorded totals and key metrics."
        case .detailed:
            "Full biometric and sample data in JSON, plus an interoperable GPX track when a route is available."
        case .custom:
            "Choose additional data and interoperability formats for a specific use."
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case summary
    case json
    case csv
    case gpx
    case tcx

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .summary: "Summary CSV"
        case .json: "Canonical JSON"
        case .csv: "Detailed CSV tables"
        case .gpx: "GPX route"
        case .tcx: "TCX workout"
        }
    }
}

struct ExportOptions: Codable, Hashable, Sendable {
    var formats: Set<ExportFormat> = [.json, .csv, .gpx, .tcx]
    var includeRawSamples = true
    var includeDerivedMetrics = true
    var includeHeartRate = true
    var includeRoute = true
    var includeSourceAndDevice = true
    var filenameFormat: ExportFilenameFormat = .dateActivityIdentifier
    var packageAsZIP = true
    var unitScheme: DistanceUnitPreference = .metric

    static func basic(
        unitScheme: DistanceUnitPreference,
        filenameFormat: ExportFilenameFormat = .dateActivityIdentifier
    ) -> ExportOptions {
        ExportOptions(
            formats: [.summary],
            includeRawSamples: false,
            includeDerivedMetrics: false,
            includeHeartRate: true,
            includeRoute: true,
            includeSourceAndDevice: true,
            filenameFormat: filenameFormat,
            packageAsZIP: false,
            unitScheme: unitScheme
        )
    }

    static func detailed(
        unitScheme: DistanceUnitPreference,
        filenameFormat: ExportFilenameFormat = .dateActivityIdentifier
    ) -> ExportOptions {
        ExportOptions(
            formats: [.json, .gpx],
            includeRawSamples: true,
            includeDerivedMetrics: true,
            includeHeartRate: true,
            includeRoute: true,
            includeSourceAndDevice: true,
            filenameFormat: filenameFormat,
            packageAsZIP: true,
            unitScheme: unitScheme
        )
    }

    var cacheKey: String {
        let units = formats.contains(.summary) ? unitScheme.rawValue : "canonical"
        return [
            "schema=\(ExportSchema.version)",
            "formats=\(formats.map(\.rawValue).sorted().joined(separator: "+"))",
            "raw=\(includeRawSamples)",
            "derived=\(includeDerivedMetrics)",
            "heartRate=\(includeHeartRate)",
            "route=\(includeRoute)",
            "source=\(includeSourceAndDevice)",
            "zip=\(packageAsZIP)",
            "units=\(units)"
        ].joined(separator: "|")
    }
}

struct ExportProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case preparing
        case summary
        case json
        case csv
        case gpx
        case tcx
        case manifest
        case archiving
        case finalizing
        case partialFailure
    }

    var phase: Phase
    var completedWorkouts: Int
    var totalWorkouts: Int

    var message: String {
        let action = switch phase {
        case .preparing: "Preparing workout data"
        case .summary: "Writing summary CSV"
        case .json: "Writing JSON"
        case .csv: "Writing CSV files"
        case .gpx: "Writing GPX route"
        case .tcx: "Writing TCX workout"
        case .manifest: "Calculating file checksums"
        case .archiving: "Creating ZIP archive"
        case .finalizing: "Finalizing export"
        case .partialFailure: "Continuing after a partial-data failure"
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
    var schemaVersion = ExportSchema.version
    var createdAt: Date
    var exporterVersion: String
    var files: [ExportFileEntry]
    var warnings: [String]
    var formats: [ExportFormat]? = nil
}

struct WorkoutExportEnvelope: Codable, Hashable, Sendable {
    var schemaName = "com.delphimon.workout-export"
    var schemaVersion = ExportSchema.version
    var exporterVersion: String
    var exportedAt: Date
    var timeZoneIdentifier: String
    var workout: WorkoutDetail
}
