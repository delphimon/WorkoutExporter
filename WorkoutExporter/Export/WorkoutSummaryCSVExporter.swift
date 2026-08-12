import Foundation

struct WorkoutSummaryExportRecord: Sendable {
    var summary: WorkoutSummary
    var locationTag: String?
    var wasExported: Bool
}

enum WorkoutSummaryCSVExporter {
    static let columns = [
        "schema_version", "workout_id", "activity_type_id", "activity_type",
        "location_tag", "start_time", "end_time", "duration_s",
        "distance", "distance_unit", "elevation_gain", "elevation_unit",
        "active_energy_kcal", "average_hr_bpm", "source_name", "source_bundle_id",
        "device_name", "device_manufacturer", "device_model", "has_route",
        "has_detailed_samples", "previously_exported",
    ]

    static func data(
        records: [WorkoutSummaryExportRecord],
        unitScheme: DistanceUnitPreference
    ) -> Data {
        var lines = [columns.joined(separator: ",")]
        lines.reserveCapacity(records.count + 1)
        for record in records {
            lines.append(row(record, unitScheme: unitScheme))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func row(
        _ record: WorkoutSummaryExportRecord,
        unitScheme: DistanceUnitPreference
    ) -> String {
        let summary = record.summary
        let distanceUnit = unitScheme == .metric ? "km" : "mi"
        let elevationUnit = unitScheme == .metric ? "m" : "ft"
        let values = [
            ExportSchema.version,
            summary.id.uuidString,
            String(summary.activityIdentifier),
            summary.activityName,
            record.locationTag ?? "",
            ExportUtilities.date(summary.startDate),
            ExportUtilities.date(summary.endDate),
            String(summary.duration),
            convertedDistance(summary.totalDistanceMeters, unitScheme: unitScheme),
            distanceUnit,
            convertedElevation(summary.elevationGainMeters, unitScheme: unitScheme),
            elevationUnit,
            optionalString(summary.activeEnergyKilocalories),
            optionalString(summary.averageHeartRateBPM),
            summary.source.name,
            summary.source.bundleIdentifier,
            summary.device?.name ?? "",
            summary.device?.manufacturer ?? "",
            summary.device?.model ?? "",
            String(summary.hasRoute),
            String(summary.hasDetailedSamples),
            String(record.wasExported),
        ]
        let externallyControlledColumns: Set<Int> = [3, 4, 14, 15, 16, 17, 18]
        return values.enumerated().map { index, value in
            externallyControlledColumns.contains(index)
                ? ExportUtilities.spreadsheetSafeCSV(value)
                : ExportUtilities.csv(value)
        }.joined(separator: ",")
    }

    private static func convertedDistance(
        _ meters: Double?,
        unitScheme: DistanceUnitPreference
    ) -> String {
        guard let meters else { return "" }
        return String(unitScheme.distanceValue(fromMeters: meters))
    }

    private static func convertedElevation(
        _ meters: Double?,
        unitScheme: DistanceUnitPreference
    ) -> String {
        guard let meters else { return "" }
        return String(
            Measurement(value: meters, unit: UnitLength.meters)
                .converted(to: unitScheme.elevationUnit).value
        )
    }

    private static func optionalString(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }
}
