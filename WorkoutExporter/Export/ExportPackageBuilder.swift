import Foundation

struct ExportPackageBuilder: ExportPackageBuilding {
    private let exporter: WorkoutFileExporter
    private let zipWriter: ZIPArchiveWriter

    init(
        exporter: WorkoutFileExporter = WorkoutFileExporter(),
        zipWriter: ZIPArchiveWriter = ZIPArchiveWriter()
    ) {
        self.exporter = exporter
        self.zipWriter = zipWriter
    }

    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL
    ) async throws -> URL {
        guard !workouts.isEmpty else { throw WorkoutExporterError.noAccessibleData }
        let staging = directory.appending(path: "WorkoutExporter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var allWarnings: [String] = []
        for (index, workout) in workouts.enumerated() {
            try Task.checkCancellation()
            let folderName = ExportUtilities.safeFilename(for: workout.summary)
            let workoutFolder = staging.appending(path: folderName, directoryHint: .isDirectory)
            _ = try await exporter.export(workout, formats: options.formats, to: workoutFolder)
            let readme = packageReadme(workout)
            try Data(readme.utf8).write(to: workoutFolder.appending(path: "README.txt"), options: .atomic)
            let manifest = try manifest(for: workoutFolder, warnings: workout.warnings)
            try encoded(manifest).write(to: workoutFolder.appending(path: "manifest.json"), options: .atomic)
            allWarnings.append(contentsOf: workout.warnings)
            if index.isMultiple(of: 4) { await Task.yield() }
        }

        if workouts.count > 1 {
            let index = workouts.map {
                "\(ExportUtilities.safeFilename(for: $0.summary)),\($0.id.uuidString),\(ExportUtilities.date($0.summary.startDate)),\(ExportUtilities.csv($0.summary.activityName))"
            }
            let text = (["folder,workout_id,start_time,activity"] + index).joined(separator: "\r\n") + "\r\n"
            try Data(text.utf8).write(to: staging.appending(path: "index.csv"), options: .atomic)
        }

        let packageName = workouts.count == 1
            ? ExportUtilities.safeFilename(for: workouts[0].summary)
            : "workout-export-\(ExportUtilities.date(Date()).prefix(10))-\(workouts.count)-workouts"
        if options.packageAsZIP {
            let destination = directory.appending(path: "\(packageName).zip")
            let files = try recursiveFiles(in: staging).map { url -> (String, Data) in
                let relative = url.path.replacingOccurrences(of: staging.path + "/", with: "")
                return (relative, try Data(contentsOf: url))
            }
            try zipWriter.write(files: files, to: destination)
            return destination
        }

        let destination = directory.appending(path: packageName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: staging, to: destination)
        return destination
    }

    private func manifest(for directory: URL, warnings: [String]) throws -> ExportManifest {
        let files = try recursiveFiles(in: directory).map { url in
            let content = try Data(contentsOf: url)
            return ExportFileEntry(
                path: url.lastPathComponent,
                contentType: contentType(url.pathExtension),
                byteSize: content.count,
                sha256: ExportUtilities.sha256(content)
            )
        }
        return ExportManifest(
            createdAt: Date(),
            exporterVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            files: files.sorted { $0.path < $1.path },
            warnings: warnings
        )
    }

    private func encoded(_ manifest: ExportManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    private func contentType(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "json": "application/json"
        case "csv": "text/csv"
        case "gpx": "application/gpx+xml"
        case "tcx": "application/vnd.garmin.tcx+xml"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    private func packageReadme(_ detail: WorkoutDetail) -> String {
        """
        Workout Exporter package
        Schema: com.delphimon.workout-export 1.0.0
        Workout: \(detail.summary.activityName) at \(ExportUtilities.date(detail.summary.startDate))

        Timestamps use ISO 8601 with fractional-second precision and an explicit UTC offset.
        Canonical distance, altitude, and speed values use meters, meters, and meters/second.
        Raw HealthKit samples remain distinct from route-derived and smoothed values.
        Provenance is recorded in JSON and relevant CSV columns.

        Metric settings:
        Moving threshold: \(detail.metricSettings.movingSpeedThresholdMetersPerSecond) m/s
        Route gap: \(detail.metricSettings.maximumRouteGap) s
        Maximum horizontal accuracy: \(detail.metricSettings.maximumHorizontalAccuracyMeters) m
        Elevation noise threshold: \(detail.metricSettings.elevationNoiseThresholdMeters) m

        Limitations:
        HealthKit can return no accessible data when read permission is denied.
        Missing route or heart-rate data is exported as missing, never fabricated.
        Derived values may differ from Apple Fitness due to proprietary smoothing,
        calibration, sensor fusion, and pause handling.
        """
    }
}
