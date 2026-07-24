import Foundation

struct WorkoutFileExporter: WorkoutExporting {
    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL
    ) async throws -> [URL] {
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var output: [URL] = []
            for format in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
                try Task.checkCancellation()
                switch format {
                case .json:
                    let url = directory.appending(path: "workout.json")
                    try json(detail).write(to: url, options: .atomic)
                    output.append(url)
                case .csv:
                    for (name, data) in csvFiles(detail) {
                        let url = directory.appending(path: name)
                        try data.write(to: url, options: .atomic)
                        output.append(url)
                    }
                case .gpx:
                    let url = directory.appending(path: "route.gpx")
                    try gpx(detail).write(to: url, options: .atomic)
                    output.append(url)
                case .tcx:
                    let url = directory.appending(path: "workout.tcx")
                    try tcx(detail).write(to: url, options: .atomic)
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

    func csvFiles(_ detail: WorkoutDetail) -> [(String, Data)] {
        [
            ("samples.csv", data(sampleCSV(detail))),
            ("route.csv", data(routeCSV(detail))),
            ("events.csv", data(eventsCSV(detail))),
            ("splits.csv", data(splitsCSV(detail))),
            ("statistics.csv", data(statisticsCSV(detail)))
        ]
    }

    func gpx(_ detail: WorkoutDetail) -> Data {
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Workout Exporter" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata><name>\(ExportUtilities.xml(detail.summary.activityName))</name><time>\(ExportUtilities.date(detail.summary.startDate))</time></metadata>
          <trk><name>\(ExportUtilities.xml(detail.summary.activityName))</name>
        """
        let heartRates = detail.heartRateSamples
        let segments = detail.routes.sorted { $0.key.uuidString < $1.key.uuidString }.map { _, points in
            let rows = points.sorted { $0.sequence < $1.sequence }.map { point in
                let heartRate = nearestHeartRate(to: point.timestamp, samples: heartRates)
                let extensionXML = heartRate.map {
                    "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(Int($0.rounded()))</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
                } ?? ""
                return "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><ele>\(point.altitudeMeters)</ele><time>\(ExportUtilities.date(point.timestamp))</time>\(extensionXML)</trkpt>"
            }.joined(separator: "\n")
            return "    <trkseg>\n\(rows)\n    </trkseg>"
        }.joined(separator: "\n")
        return data("\(header)\n\(segments)\n  </trk>\n</gpx>\n")
    }

    func tcx(_ detail: WorkoutDetail) -> Data {
        let sport = tcxSport(detail.summary.activityName)
        let points = detail.routePoints.map { point in
            let heartRate = nearestHeartRate(to: point.timestamp, samples: detail.heartRateSamples)
            let hr = heartRate.map { "<HeartRateBpm><Value>\(Int($0.rounded()))</Value></HeartRateBpm>" } ?? ""
            return """
                  <Trackpoint><Time>\(ExportUtilities.date(point.timestamp))</Time><Position><LatitudeDegrees>\(point.latitude)</LatitudeDegrees><LongitudeDegrees>\(point.longitude)</LongitudeDegrees></Position><AltitudeMeters>\(point.altitudeMeters)</AltitudeMeters>\(hr)</Trackpoint>
            """
        }.joined(separator: "\n")
        let distance = detail.summary.totalDistanceMeters ?? detail.derived.routeDistanceMeters?.value ?? 0
        let calories = Int((detail.summary.activeEnergyKilocalories ?? 0).rounded())
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities><Activity Sport="\(sport)"><Id>\(ExportUtilities.date(detail.summary.startDate))</Id>
            <Lap StartTime="\(ExportUtilities.date(detail.summary.startDate))"><TotalTimeSeconds>\(detail.summary.duration)</TotalTimeSeconds><DistanceMeters>\(distance)</DistanceMeters><Calories>\(calories)</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>
        \(points)
            </Track></Lap></Activity></Activities>
        </TrainingCenterDatabase>
        """
        return data(xml)
    }

    private func sampleCSV(_ detail: WorkoutDetail) -> String {
        let header = "workout_id,sample_type,start_time,end_time,value,unit,source_name,source_bundle_id,device_name,provenance,metadata_json"
        let rows = detail.samples.map { sample in
            [
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
            ].map(ExportUtilities.csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private func routeCSV(_ detail: WorkoutDetail) -> String {
        let header = "workout_id,route_id,sequence,timestamp,latitude,longitude,altitude_m,horizontal_accuracy_m,vertical_accuracy_m,speed_mps,speed_accuracy_mps,course_deg,course_accuracy_deg,segment_distance_m,cumulative_distance_m,derived_speed_mps,smoothed_speed_mps,grade,quality_flags"
        var cumulative = 0.0
        var previous: RoutePoint?
        let rows = detail.routePoints.map { point -> String in
            let segmentDistance: Double
            let derivedSpeed: Double?
            if let previous, previous.routeID == point.routeID {
                let latScale = 111_132.0
                let lonScale = 111_320.0 * cos(point.latitude * .pi / 180)
                let dy = (point.latitude - previous.latitude) * latScale
                let dx = (point.longitude - previous.longitude) * lonScale
                segmentDistance = hypot(dx, dy)
                let delta = point.timestamp.timeIntervalSince(previous.timestamp)
                derivedSpeed = delta > 0 ? segmentDistance / delta : nil
            } else {
                segmentDistance = 0
                derivedSpeed = nil
            }
            cumulative += segmentDistance
            previous = point
            let columns: [String] = [
                detail.id.uuidString, point.routeID.uuidString, String(point.sequence),
                ExportUtilities.date(point.timestamp), String(point.latitude), String(point.longitude),
                String(point.altitudeMeters), String(point.horizontalAccuracyMeters), String(point.verticalAccuracyMeters),
                optionalString(point.speedMetersPerSecond), optionalString(point.speedAccuracyMetersPerSecond),
                optionalString(point.courseDegrees), optionalString(point.courseAccuracyDegrees),
                String(segmentDistance), String(cumulative), optionalString(derivedSpeed), "", "",
                point.qualityFlags.joined(separator: "|")
            ]
            return columns.map(ExportUtilities.csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private func eventsCSV(_ detail: WorkoutDetail) -> String {
        let header = "workout_id,event_type,start_time,end_time,metadata_json"
        let rows = detail.events.map {
            [detail.id.uuidString, $0.kind.rawValue, ExportUtilities.date($0.startDate), $0.endDate.map(ExportUtilities.date) ?? "", ExportUtilities.metadataJSON($0.metadata)]
                .map(ExportUtilities.csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private func splitsCSV(_ detail: WorkoutDetail) -> String {
        let header = "workout_id,index,start_time,end_time,distance_m,elapsed_s,moving_s,pace_s_per_km,speed_mps,elevation_gain_m,elevation_loss_m,average_hr_bpm,maximum_hr_bpm"
        let rows = detail.derived.splits.map { split -> String in
            let columns: [String] = [
                detail.id.uuidString,
                String(split.index),
                ExportUtilities.date(split.startDate),
                ExportUtilities.date(split.endDate),
                String(split.distanceMeters),
                String(split.elapsedTime),
                String(split.movingTime),
                optionalString(split.paceSecondsPerKilometer),
                optionalString(split.speedMetersPerSecond),
                String(split.elevationGainMeters),
                String(split.elevationLossMeters),
                optionalString(split.averageHeartRateBPM),
                optionalString(split.maximumHeartRateBPM)
            ]
            return columns.map(ExportUtilities.csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private func statisticsCSV(_ detail: WorkoutDetail) -> String {
        let header = "workout_id,sample_type,aggregation,value,unit,provenance"
        let rows = detail.statistics.map {
            [detail.id.uuidString, $0.typeIdentifier, $0.aggregation, String($0.value), $0.unit, DataProvenance.healthKitStatistic.rawValue]
                .map(ExportUtilities.csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private func nearestHeartRate(to date: Date, samples: [WorkoutSample]) -> Double? {
        samples.min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
            .flatMap { abs($0.startDate.timeIntervalSince(date)) <= 10 ? $0.value : nil }
    }

    private func tcxSport(_ activity: String) -> String {
        switch activity.lowercased() {
        case let value where value.contains("run"): "Running"
        case let value where value.contains("cycl"): "Biking"
        default: "Other"
        }
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func optionalString(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
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
