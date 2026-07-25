import Foundation

struct WorkoutFileExporter: WorkoutExporting {
    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress.Phase) async -> Void
    ) async throws -> [URL] {
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var output: [URL] = []
            for format in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
                try Task.checkCancellation()
                await progress(format.progressPhase)
                switch format {
                case .json:
                    let url = directory.appending(path: "workout.json")
                    try json(detail).write(to: url, options: .atomic)
                    output.append(url)
                case .csv:
                    output.append(contentsOf: try writeCSVFiles(detail, to: directory))
                case .gpx:
                    let url = directory.appending(path: "route.gpx")
                    try writeFile(to: url) { try writeGPX(detail, to: $0) }
                    output.append(url)
                case .tcx:
                    let url = directory.appending(path: "workout.tcx")
                    try writeFile(to: url) { try writeTCX(detail, to: $0) }
                    output.append(url)
                }
            }
            return output
        } catch is CancellationError {
            throw WorkoutExporterError.cancelled
        } catch let error as WorkoutExporterError {
            throw error
        } catch {
            throw WorkoutExporterError.fileWriteFailure(error.localizedDescription)
        }
    }

    func json(_ detail: WorkoutDetail) throws -> Data {
        let envelope = WorkoutExportEnvelope(
            exporterVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            exportedAt: Date(),
            timeZoneIdentifier: TimeZone.current.identifier,
            workout: detail
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw WorkoutExporterError.encodingFailure(error.localizedDescription)
        }
    }

    func csvFiles(_ detail: WorkoutDetail) throws -> [(String, Data)] {
        [
            ("samples.csv", try rendered { try writeSampleCSV(detail, to: $0) }),
            ("route.csv", try rendered { try writeRouteCSV(detail, to: $0) }),
            ("events.csv", try rendered { try writeEventsCSV(detail, to: $0) }),
            ("splits.csv", try rendered { try writeSplitsCSV(detail, to: $0) }),
            ("statistics.csv", try rendered { try writeStatisticsCSV(detail, to: $0) })
        ]
    }

    func gpx(_ detail: WorkoutDetail) throws -> Data {
        try rendered { try writeGPX(detail, to: $0) }
    }

    func tcx(_ detail: WorkoutDetail) throws -> Data {
        try rendered { try writeTCX(detail, to: $0) }
    }

    private func writeCSVFiles(_ detail: WorkoutDetail, to directory: URL) throws -> [URL] {
        let files: [(String, (any ExportTextWriting) throws -> Void)] = [
            ("samples.csv", { try writeSampleCSV(detail, to: $0) }),
            ("route.csv", { try writeRouteCSV(detail, to: $0) }),
            ("events.csv", { try writeEventsCSV(detail, to: $0) }),
            ("splits.csv", { try writeSplitsCSV(detail, to: $0) }),
            ("statistics.csv", { try writeStatisticsCSV(detail, to: $0) })
        ]
        return try files.map { name, body in
            try Task.checkCancellation()
            let url = directory.appending(path: name)
            try writeFile(to: url, body)
            return url
        }
    }

    private func writeGPX(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="Workout Exporter" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
              <metadata><name>\(ExportUtilities.xml(detail.summary.activityName))</name><time>\(ExportUtilities.date(detail.summary.startDate))</time></metadata>
              <trk><name>\(ExportUtilities.xml(detail.summary.activityName))</name>

            """
        )
        let heartRateLookup = HeartRateLookup(samples: detail.heartRateSamples)
        let routes = detail.routes.values.sorted {
            ($0.first?.timestamp ?? .distantFuture) < ($1.first?.timestamp ?? .distantFuture)
        }
        for points in routes {
            try Task.checkCancellation()
            try writer.write("    <trkseg>\n")
            for (index, point) in points.sorted(by: { $0.sequence < $1.sequence }).enumerated() {
                try checkCancellation(at: index)
                let extensionXML = heartRateLookup.value(nearestTo: point.timestamp).map {
                    "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(Int($0.rounded()))</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
                } ?? ""
                try writer.write(
                    "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><ele>\(point.altitudeMeters)</ele><time>\(ExportUtilities.date(point.timestamp))</time>\(extensionXML)</trkpt>\n"
                )
            }
            try writer.write("    </trkseg>\n")
        }
        try writer.write("  </trk>\n</gpx>\n")
    }

    private func writeTCX(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        let distance = detail.summary.totalDistanceMeters ?? detail.derived.routeDistanceMeters?.value ?? 0
        let calories = Int((detail.summary.activeEnergyKilocalories ?? 0).rounded())
        try writer.write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
              <Activities><Activity Sport="\(tcxSport(detail.summary.activityName))"><Id>\(ExportUtilities.date(detail.summary.startDate))</Id>
                <Lap StartTime="\(ExportUtilities.date(detail.summary.startDate))"><TotalTimeSeconds>\(detail.summary.duration)</TotalTimeSeconds><DistanceMeters>\(distance)</DistanceMeters><Calories>\(calories)</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>

            """
        )
        let heartRateLookup = HeartRateLookup(samples: detail.heartRateSamples)
        for (index, point) in detail.routePoints.enumerated() {
            try checkCancellation(at: index)
            let heartRate = heartRateLookup.value(nearestTo: point.timestamp)
            let heartRateXML = heartRate.map {
                "<HeartRateBpm><Value>\(Int($0.rounded()))</Value></HeartRateBpm>"
            } ?? ""
            try writer.write(
                "      <Trackpoint><Time>\(ExportUtilities.date(point.timestamp))</Time><Position><LatitudeDegrees>\(point.latitude)</LatitudeDegrees><LongitudeDegrees>\(point.longitude)</LongitudeDegrees></Position><AltitudeMeters>\(point.altitudeMeters)</AltitudeMeters>\(heartRateXML)</Trackpoint>\n"
            )
        }
        try writer.write(
            """
                </Track></Lap></Activity></Activities>
            </TrainingCenterDatabase>

            """
        )
    }

    private func writeSampleCSV(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write("workout_id,sample_type,start_time,end_time,value,unit,source_name,source_bundle_id,device_name,provenance,metadata_json\r\n")
        for (index, sample) in detail.samples.enumerated() {
            try checkCancellation(at: index)
            let columns = [
                detail.id.uuidString,
                sample.typeIdentifier,
                ExportUtilities.date(sample.startDate),
                ExportUtilities.date(sample.endDate),
                String(sample.value),
                sample.unit,
                sample.source.name,
                sample.source.bundleIdentifier,
                sample.device?.name ?? "",
                sample.provenance.rawValue,
                ExportUtilities.metadataJSON(sample.metadata)
            ]
            try writer.write(columns.map(ExportUtilities.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func writeRouteCSV(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write("workout_id,route_id,sequence,timestamp,latitude,longitude,altitude_m,horizontal_accuracy_m,vertical_accuracy_m,speed_mps,speed_accuracy_mps,course_deg,course_accuracy_deg,segment_distance_m,cumulative_distance_m,derived_speed_mps,smoothed_speed_mps,grade,quality_flags\r\n")
        var cumulative = 0.0
        var previous: RoutePoint?
        for (index, point) in detail.routePoints.enumerated() {
            try checkCancellation(at: index)
            let segmentDistance: Double
            let derivedSpeed: Double?
            if let previous, previous.routeID == point.routeID {
                let latitudeScale = 111_132.0
                let longitudeScale = 111_320.0 * cos(point.latitude * .pi / 180)
                let latitudeDelta = (point.latitude - previous.latitude) * latitudeScale
                let longitudeDelta = (point.longitude - previous.longitude) * longitudeScale
                segmentDistance = hypot(longitudeDelta, latitudeDelta)
                let timeDelta = point.timestamp.timeIntervalSince(previous.timestamp)
                derivedSpeed = timeDelta > 0 ? segmentDistance / timeDelta : nil
            } else {
                segmentDistance = 0
                derivedSpeed = nil
            }
            cumulative += segmentDistance
            previous = point
            let columns = [
                detail.id.uuidString, point.routeID.uuidString, String(point.sequence),
                ExportUtilities.date(point.timestamp), String(point.latitude), String(point.longitude),
                String(point.altitudeMeters), String(point.horizontalAccuracyMeters), String(point.verticalAccuracyMeters),
                optionalString(point.speedMetersPerSecond), optionalString(point.speedAccuracyMetersPerSecond),
                optionalString(point.courseDegrees), optionalString(point.courseAccuracyDegrees),
                String(segmentDistance), String(cumulative), optionalString(derivedSpeed), "", "",
                point.qualityFlags.joined(separator: "|")
            ]
            try writer.write(columns.map(ExportUtilities.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func writeEventsCSV(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write("workout_id,event_type,start_time,end_time,metadata_json\r\n")
        for (index, event) in detail.events.enumerated() {
            try checkCancellation(at: index)
            let columns = [
                detail.id.uuidString,
                event.kind.rawValue,
                ExportUtilities.date(event.startDate),
                event.endDate.map(ExportUtilities.date) ?? "",
                ExportUtilities.metadataJSON(event.metadata)
            ]
            try writer.write(columns.map(ExportUtilities.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func writeSplitsCSV(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write("workout_id,index,start_time,end_time,distance_m,elapsed_s,moving_s,pace_s_per_km,speed_mps,elevation_gain_m,elevation_loss_m,average_hr_bpm,maximum_hr_bpm\r\n")
        for (index, split) in detail.derived.splits.enumerated() {
            try checkCancellation(at: index)
            let columns = [
                detail.id.uuidString,
                String(split.index),
                ExportUtilities.date(split.startDate),
                ExportUtilities.date(split.endDate),
                String(split.distanceMeters),
                String(split.elapsedTime),
                String(split.movingTime),
                optionalString(split.paceSecondsPerKilometer),
                optionalString(split.speedMetersPerSecond),
                optionalString(split.elevationGainMeters),
                optionalString(split.elevationLossMeters),
                optionalString(split.averageHeartRateBPM),
                optionalString(split.maximumHeartRateBPM)
            ]
            try writer.write(columns.map(ExportUtilities.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func writeStatisticsCSV(_ detail: WorkoutDetail, to writer: any ExportTextWriting) throws {
        try writer.write("workout_id,sample_type,aggregation,value,unit,provenance\r\n")
        for (index, statistic) in detail.statistics.enumerated() {
            try checkCancellation(at: index)
            let columns = [
                detail.id.uuidString,
                statistic.typeIdentifier,
                statistic.aggregation,
                String(statistic.value),
                statistic.unit,
                DataProvenance.healthKitStatistic.rawValue
            ]
            try writer.write(columns.map(ExportUtilities.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func rendered(_ body: (any ExportTextWriting) throws -> Void) throws -> Data {
        let writer = DataExportTextWriter()
        try body(writer)
        return writer.data
    }

    private func writeFile(
        to url: URL,
        _ body: (any ExportTextWriting) throws -> Void
    ) throws {
        let writer = try FileExportTextWriter(url: url)
        do {
            try body(writer)
            try writer.finish()
        } catch {
            try? writer.finish()
            throw error
        }
    }

    private func checkCancellation(at index: Int) throws {
        if index.isMultiple(of: 128) {
            try Task.checkCancellation()
        }
    }

    private func tcxSport(_ activity: String) -> String {
        switch activity.lowercased() {
        case let value where value.contains("run"): "Running"
        case let value where value.contains("cycl"): "Biking"
        default: "Other"
        }
    }

    private func optionalString(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }
}

struct HeartRateLookup: Sendable {
    private let samples: [WorkoutSample]

    init(samples: [WorkoutSample]) {
        self.samples = samples.sorted { $0.startDate < $1.startDate }
    }

    func value(nearestTo date: Date, maximumDifference: TimeInterval = 10) -> Double? {
        guard !samples.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = samples.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if samples[middle].startDate < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        var candidateIndices: [Int] = []
        if lowerBound < samples.count { candidateIndices.append(lowerBound) }
        if lowerBound > 0 { candidateIndices.append(lowerBound - 1) }
        guard let nearest = candidateIndices.min(by: {
            abs(samples[$0].startDate.timeIntervalSince(date))
                < abs(samples[$1].startDate.timeIntervalSince(date))
        }) else {
            return nil
        }
        let sample = samples[nearest]
        return abs(sample.startDate.timeIntervalSince(date)) <= maximumDifference ? sample.value : nil
    }
}

private extension ExportFormat {
    var progressPhase: ExportProgress.Phase {
        switch self {
        case .json: .json
        case .csv: .csv
        case .gpx: .gpx
        case .tcx: .tcx
        }
    }
}

private protocol ExportTextWriting: AnyObject {
    func write(_ text: String) throws
}

private final class DataExportTextWriter: ExportTextWriting {
    private(set) var data = Data()

    func write(_ text: String) {
        data.append(contentsOf: text.utf8)
    }
}

private final class FileExportTextWriter: ExportTextWriting {
    private static let bufferLimit = 64 * 1_024
    private let handle: FileHandle
    private var buffer = Data()
    private var isFinished = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WorkoutExporterError.fileWriteFailure("Could not create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.bufferLimit)
    }

    func write(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.bufferLimit {
            try flush()
        }
    }

    func finish() throws {
        guard !isFinished else { return }
        try flush()
        try handle.close()
        isFinished = true
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ExportUtilities.date(date))
        }
    }
}
