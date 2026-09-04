import ActivityArchiveCore
import Foundation

struct ActivityPackageWorkoutAdapter: Sendable {
    private let exporter: WorkoutFileExporter

    init(exporter: WorkoutFileExporter = WorkoutFileExporter()) {
        self.exporter = exporter
    }

    func write(
        _ detail: WorkoutDetail,
        locationTag: String?,
        options: ExportOptions,
        to destination: URL
    ) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appending(
            path: ".ActivityManager-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try ExportUtilities.createProtectedDirectory(at: staging)
        defer { try? manager.removeItem(at: staging) }

        let sourceID = "healthkit:\(detail.id.uuidString.lowercased())"
        let generatedAt = Date()
        var payloads: [ActivityPackagePayload] = []
        var metricSeries: [ActivityMetricSeriesDescriptor] = []
        var routes: [ActivityRouteDescriptor] = []
        var provenance: [ActivityProvenanceRecord] = []

        let workoutPath = "source/workout.json"
        let workoutURL = staging.appending(path: "workout.json")
        try ExportUtilities.writeProtected(
            try encoder().encode(ActivityManagerSourceWorkout(detail: detail)),
            to: workoutURL
        )
        payloads.append(
            ActivityPackagePayload(
                path: workoutPath,
                role: .sourceWorkout,
                mediaType: "application/json",
                authority: .authoritative,
                fileURL: workoutURL
            )
        )
        provenance.append(
            try provenanceRecord(
                sourceID: sourceID,
                path: workoutPath,
                parser: "HealthKit workout adapter",
                recordedAt: detail.summary.endDate
            )
        )

        if !detail.samples.isEmpty {
            let path = "metrics/quantity-samples.jsonl"
            let url = staging.appending(path: "quantity-samples.jsonl")
            try writeJSONLines(detail.samples, to: url)
            payloads.append(
                ActivityPackagePayload(
                    path: path,
                    role: .metricSeries,
                    mediaType: "application/x-ndjson",
                    authority: .authoritative,
                    fileURL: url
                )
            )
            metricSeries.append(contentsOf: quantitySeries(detail.samples, payloadPath: path))
            provenance.append(
                try provenanceRecord(
                    sourceID: sourceID,
                    path: path,
                    parser: "HealthKit quantity sample adapter",
                    recordedAt: detail.summary.endDate
                )
            )
        }

        if !detail.categorySamples.isEmpty {
            let path = "metrics/category-samples.jsonl"
            let url = staging.appending(path: "category-samples.jsonl")
            try writeJSONLines(detail.categorySamples, to: url)
            payloads.append(
                ActivityPackagePayload(
                    path: path,
                    role: .metricSeries,
                    mediaType: "application/x-ndjson",
                    authority: .authoritative,
                    fileURL: url
                )
            )
            metricSeries.append(
                contentsOf: categorySeries(detail.categorySamples, payloadPath: path))
            provenance.append(
                try provenanceRecord(
                    sourceID: sourceID,
                    path: path,
                    parser: "HealthKit category sample adapter",
                    recordedAt: detail.summary.endDate
                )
            )
        }

        if !detail.routes.isEmpty {
            let routePath = "source/route-points.jsonl"
            let routeURL = staging.appending(path: "route-points.jsonl")
            try writeRoutePoints(detail.routes, to: routeURL)
            payloads.append(
                ActivityPackagePayload(
                    path: routePath,
                    role: .authoritativeRoute,
                    mediaType: "application/x-ndjson",
                    authority: .authoritative,
                    fileURL: routeURL
                )
            )
            provenance.append(
                try provenanceRecord(
                    sourceID: sourceID,
                    path: routePath,
                    parser: "HealthKit workout route adapter",
                    recordedAt: detail.summary.endDate
                )
            )

            let gpxPath = "source/route.gpx"
            let gpxURL = staging.appending(path: "route.gpx")
            try exporter.writeGPXFile(detail, to: gpxURL)
            payloads.append(
                ActivityPackagePayload(
                    path: gpxPath,
                    role: .interoperableRoute,
                    mediaType: "application/gpx+xml",
                    authority: .supplemental,
                    fileURL: gpxURL
                )
            )
            provenance.append(
                try provenanceRecord(
                    sourceID: sourceID,
                    path: gpxPath,
                    parser: "Activity Manager GPX projection",
                    recordedAt: detail.summary.endDate
                )
            )

            routes = detail.routes.keys.sorted(by: { $0.uuidString < $1.uuidString }).compactMap {
                routeID in
                guard let points = detail.routes[routeID] else { return nil }
                return ActivityRouteDescriptor(
                    trackID: routeID.uuidString.lowercased(),
                    authoritativePath: routePath,
                    interoperablePaths: [gpxPath],
                    elevationUnit: "m",
                    segmentCount: 1,
                    pointCount: UInt64(points.count),
                    hasTimestamps: true,
                    completeness: .final,
                    source: detail.summary.source.name
                )
            }
        }

        let hasMetrics = !detail.samples.isEmpty || !detail.categorySamples.isEmpty
        let routeState: ActivityPackageRouteState =
            if !options.includeRoute {
                .intentionallyExcluded
            } else if detail.routes.isEmpty {
                .unavailable
            } else {
                .included
            }
        let metricsState: ActivityPackageMetricsState =
            if !options.includeRawSamples {
                .intentionallyExcluded
            } else if !hasMetrics {
                .unavailable
            } else {
                .included
            }

        var omissions: [String] = []
        if routeState == .unavailable {
            omissions.append("No HealthKit workout route was accessible.")
        } else if routeState == .intentionallyExcluded {
            omissions.append("Route data was intentionally excluded by the export settings.")
        }
        if metricsState == .unavailable {
            omissions.append("No associated HealthKit metric samples were accessible.")
        } else if metricsState == .intentionallyExcluded {
            omissions.append(
                "Raw metric samples were intentionally excluded by the export settings.")
        }
        if !options.includeHeartRate {
            omissions.append("Heart-rate data was intentionally excluded by the export settings.")
        }
        if !options.includeSourceAndDevice {
            omissions.append("Source and device identifiers were intentionally redacted.")
        }

        let annotations: [ActivityUserAnnotation] =
            locationTag.map {
                [
                    ActivityUserAnnotation(
                        key: "locationTag",
                        value: $0,
                        modifiedAt: detail.summary.endDate
                    )
                ]
            } ?? []
        let source = detail.summary.source
        let device = detail.summary.device
        let draft = ActivityPackageDraft(
            packageID: try ActivityPackageIdentity.stablePackageID(for: sourceID),
            packageRevision: 1,
            generatedAt: generatedAt,
            generator: ActivityPackageGenerator(
                name: "Activity Manager",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "development"
            ),
            source: ActivitySourceIdentity(
                sourceActivityID: sourceID,
                originalIdentifier: detail.id.uuidString.lowercased(),
                sourceBundleIdentifier: source.bundleIdentifier,
                sourceName: source.name,
                sourceVersion: source.version,
                deviceName: device?.name,
                deviceModel: device?.model
            ),
            workoutTypeIdentifier: detail.summary.activityIdentifier,
            workoutTypeName: detail.summary.activityName,
            startDate: detail.summary.startDate,
            endDate: detail.summary.endDate,
            timeZoneIdentifier: detail.activityTimeZone.identifier,
            durationSeconds: detail.summary.duration,
            events: detail.events.map {
                ActivityPackageEvent(
                    eventType: $0.kind.rawValue,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    source: source.name,
                    details: $0.metadata
                )
            },
            metricSeries: metricSeries,
            routes: routes,
            provenance: provenance,
            userAnnotations: annotations,
            completeness: .final,
            routeState: routeState,
            metricsState: metricsState,
            sourceReportedStatistics: sourceStatistics(detail),
            knownOmissions: omissions,
            privacyClassifications: privacyClassifications(
                includesMetrics: hasMetrics,
                includesRoute: !detail.routes.isEmpty
            )
        )

        _ = try ActivityPackageWriter.write(draft: draft, payloads: payloads, to: destination)
        try ExportUtilities.applyCompleteFileProtection(to: destination)
    }

    private func sourceStatistics(_ detail: WorkoutDetail) -> [ActivityPackageStatistic] {
        var statistics = detail.statistics.map {
            ActivityPackageStatistic(
                identifier: $0.typeIdentifier,
                aggregation: $0.aggregation,
                value: $0.value,
                unit: $0.unit,
                provenance: DataProvenance.healthKitStatistic.rawValue
            )
        }
        let summary = detail.summary
        let values: [(String, Double?, String)] = [
            ("HKWorkout.totalDistance", summary.totalDistanceMeters, "m"),
            ("HKWorkout.elevationGain", summary.elevationGainMeters, "m"),
            ("HKWorkout.activeEnergy", summary.activeEnergyKilocalories, "kcal"),
            ("HKWorkout.averageHeartRate", summary.averageHeartRateBPM, "count/min"),
        ]
        statistics.append(
            contentsOf: values.compactMap { identifier, value, unit in
                value.map {
                    ActivityPackageStatistic(
                        identifier: identifier,
                        aggregation: "sourceReported",
                        value: $0,
                        unit: unit,
                        provenance: "HKWorkout"
                    )
                }
            }
        )
        return statistics
    }

    private func quantitySeries(
        _ samples: [WorkoutSample],
        payloadPath: String
    ) -> [ActivityMetricSeriesDescriptor] {
        struct Key: Hashable {
            var identifier: String
            var unit: String
            var source: String
        }
        struct Summary {
            var count: UInt64
            var start: Date
            var end: Date
        }
        var summaries: [Key: Summary] = [:]
        for sample in samples {
            let key = Key(
                identifier: sample.typeIdentifier,
                unit: sample.unit,
                source: sample.source.name
            )
            if var summary = summaries[key] {
                summary.count += 1
                summary.start = min(summary.start, sample.startDate)
                summary.end = max(summary.end, sample.endDate)
                summaries[key] = summary
            } else {
                summaries[key] = Summary(count: 1, start: sample.startDate, end: sample.endDate)
            }
        }
        return summaries.sorted {
            ($0.key.identifier, $0.key.unit, $0.key.source)
                < ($1.key.identifier, $1.key.unit, $1.key.source)
        }.map { key, summary in
            ActivityMetricSeriesDescriptor(
                seriesID: stableSeriesID(
                    kind: "quantity",
                    identifier: key.identifier,
                    unit: key.unit,
                    source: key.source
                ),
                identifier: key.identifier,
                payloadPath: payloadPath,
                sourceUnit: key.unit,
                aggregation: "discrete",
                startDate: summary.start,
                endDate: summary.end,
                sampleCount: summary.count,
                source: key.source
            )
        }
    }

    private func categorySeries(
        _ samples: [CategorySample],
        payloadPath: String
    ) -> [ActivityMetricSeriesDescriptor] {
        struct Key: Hashable {
            var identifier: String
            var source: String
        }
        struct Summary {
            var count: UInt64
            var start: Date
            var end: Date
        }
        var summaries: [Key: Summary] = [:]
        for sample in samples {
            let key = Key(identifier: sample.typeIdentifier, source: sample.source.name)
            if var summary = summaries[key] {
                summary.count += 1
                summary.start = min(summary.start, sample.startDate)
                summary.end = max(summary.end, sample.endDate)
                summaries[key] = summary
            } else {
                summaries[key] = Summary(count: 1, start: sample.startDate, end: sample.endDate)
            }
        }
        return summaries.sorted {
            ($0.key.identifier, $0.key.source) < ($1.key.identifier, $1.key.source)
        }.map { key, summary in
            ActivityMetricSeriesDescriptor(
                seriesID: stableSeriesID(
                    kind: "category",
                    identifier: key.identifier,
                    unit: "category-code",
                    source: key.source
                ),
                identifier: key.identifier,
                payloadPath: payloadPath,
                sourceUnit: "category-code",
                aggregation: "category",
                startDate: summary.start,
                endDate: summary.end,
                sampleCount: summary.count,
                source: key.source
            )
        }
    }

    private func stableSeriesID(
        kind: String,
        identifier: String,
        unit: String,
        source: String
    ) -> String {
        let fingerprint = "\(kind)|\(identifier)|\(unit)|\(source)"
        return "\(kind)-\(ExportUtilities.sha256(Data(fingerprint.utf8)).prefix(20))"
    }

    private func provenanceRecord(
        sourceID: String,
        path: String,
        parser: String,
        recordedAt: Date
    ) throws -> ActivityProvenanceRecord {
        ActivityProvenanceRecord(
            recordID: try ActivityPackageIdentity.stablePackageID(for: "\(sourceID)|\(path)"),
            subjectPath: path,
            sourceActivityID: sourceID,
            parserName: parser,
            parserVersion: ExportSchema.version,
            recordedAt: recordedAt
        )
    }

    private func privacyClassifications(
        includesMetrics: Bool,
        includesRoute: Bool
    ) -> [ActivityPackagePrivacyClassification] {
        if includesMetrics && includesRoute { return [.healthAndPreciseLocation] }
        if includesMetrics { return [.health] }
        if includesRoute { return [.preciseLocation] }
        return [.privateMetadata]
    }

    private func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
        let writer = try JSONLineWriter(url: url, encoder: encoder())
        do {
            for (index, value) in values.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                try writer.write(value)
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    private func writeRoutePoints(_ routes: [UUID: [RoutePoint]], to url: URL) throws {
        let writer = try JSONLineWriter(url: url, encoder: encoder())
        do {
            var index = 0
            for routeID in routes.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                for point in (routes[routeID] ?? []).sorted(by: { $0.sequence < $1.sequence }) {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    try writer.write(point)
                    index += 1
                }
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .activityManagerISO8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct ActivityManagerSourceWorkout: Codable {
    var schemaName = "com.delphimon.activity-manager.source-workout"
    var schemaVersion = "1.0.0"
    var summary: WorkoutSummary
    var events: [WorkoutEvent]
    var activities: [WorkoutActivitySegment]
    var statistics: [NativeStatistic]
    var metadata: [String: String]
    var derived: DerivedMetrics
    var metricSettings: MetricCalculationSettings
    var warnings: [String]

    init(detail: WorkoutDetail) {
        summary = detail.summary
        events = detail.events
        activities = detail.activities
        statistics = detail.statistics
        metadata = detail.metadata
        derived = detail.derived
        derived.routeMetrics = nil
        metricSettings = detail.metricSettings
        warnings = detail.warnings
    }
}

private final class JSONLineWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var isFinished = false

    init(url: URL, encoder: JSONEncoder) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WorkoutExporterError.fileWriteFailure(
                "Could not create \(url.lastPathComponent).")
        }
        try ExportUtilities.applyCompleteFileProtection(to: url)
        handle = try FileHandle(forWritingTo: url)
        self.encoder = encoder
    }

    func write<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0a)
        try handle.write(contentsOf: data)
    }

    func finish() throws {
        guard !isFinished else { return }
        try handle.synchronize()
        try handle.close()
        isFinished = true
    }

    func cancel() {
        guard !isFinished else { return }
        try? handle.close()
        isFinished = true
    }

    deinit {
        cancel()
    }
}

extension JSONEncoder.DateEncodingStrategy {
    fileprivate static var activityManagerISO8601: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ExportUtilities.date(date))
        }
    }
}
