import Foundation

actor ExportPackageBuilder: ExportPackageBuilding {
    private let exporter: any WorkoutExporting
    private let zipWriter: ZIPArchiveWriter

    init(
        exporter: any WorkoutExporting = WorkoutFileExporter(),
        zipWriter: ZIPArchiveWriter = ZIPArchiveWriter()
    ) {
        self.exporter = exporter
        self.zipWriter = zipWriter
    }

    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> URL {
        do {
            guard !workouts.isEmpty else { throw WorkoutExporterError.noAccessibleData }
            let staging = directory.appending(path: "WorkoutExporter-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            for (index, workout) in workouts.enumerated() {
                try Task.checkCancellation()
                await progress(update(.preparing, index: index, total: workouts.count))
                let preparedWorkout = filtered(workout, options: options)
                let folderName = ExportUtilities.safeFilename(for: preparedWorkout.summary)
                let workoutFolder = staging.appending(path: folderName, directoryHint: .isDirectory)
                _ = try await exporter.export(
                    preparedWorkout,
                    formats: options.formats,
                    to: workoutFolder
                ) { phase in
                    await progress(self.update(phase, index: index, total: workouts.count))
                }
                let readme = packageReadme(preparedWorkout)
                try Data(readme.utf8).write(to: workoutFolder.appending(path: "README.txt"), options: .atomic)
                await progress(update(.manifest, index: index, total: workouts.count))
                let manifest = try manifest(for: workoutFolder, warnings: preparedWorkout.warnings)
                try encoded(manifest).write(to: workoutFolder.appending(path: "manifest.json"), options: .atomic)
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
                await progress(update(.archiving, index: workouts.count - 1, total: workouts.count))
                let destination = directory.appending(path: "\(packageName).zip")
                let files = try recursiveFiles(in: staging).map { url -> (String, URL) in
                    let relative = url.path.replacingOccurrences(of: staging.path + "/", with: "")
                    return (relative, url)
                }
                try zipWriter.write(files: files, to: destination)
                await progress(update(.finalizing, index: workouts.count - 1, total: workouts.count))
                return destination
            }

            await progress(update(.finalizing, index: workouts.count - 1, total: workouts.count))
            let destination = directory.appending(path: packageName, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: staging, to: destination)
            return destination
        } catch is CancellationError {
            throw WorkoutExporterError.cancelled
        } catch let error as WorkoutExporterError {
            throw error
        } catch {
            throw WorkoutExporterError.fileWriteFailure(error.localizedDescription)
        }
    }

    private func filtered(_ workout: WorkoutDetail, options: ExportOptions) -> WorkoutDetail {
        var result = workout
        if !options.includeRawSamples {
            result.samples = []
            result.categorySamples = []
        }
        if !options.includeHeartRate {
            result.samples.removeAll { $0.typeIdentifier == "HKQuantityTypeIdentifierHeartRate" }
            result.summary.averageHeartRateBPM = nil
            result.derived.averageHeartRateBPM = nil
            result.derived.minimumHeartRateBPM = nil
            result.derived.maximumHeartRateBPM = nil
        }
        if !options.includeRoute {
            result.routes = [:]
        }
        if !options.includeDerivedMetrics {
            result.derived = .empty
        }
        if !options.includeSourceAndDevice {
            let redacted = SourceInfo(name: "Redacted", bundleIdentifier: "", version: nil, operatingSystemVersion: nil)
            result.summary.source = redacted
            result.summary.device = nil
            result.samples = result.samples.map { sample in
                var sample = sample
                sample.source = redacted
                sample.device = nil
                return sample
            }
            result.categorySamples = result.categorySamples.map { sample in
                var sample = sample
                sample.source = redacted
                return sample
            }
        }
        return result
    }

    private func manifest(for directory: URL, warnings: [String]) throws -> ExportManifest {
        let files = try recursiveFiles(in: directory).map { url in
            try Task.checkCancellation()
            let hash = try ExportUtilities.sha256(fileAt: url)
            return ExportFileEntry(
                path: url.lastPathComponent,
                contentType: contentType(url.pathExtension),
                byteSize: hash.byteSize,
                sha256: hash.digest
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
        HealthKit workout statistics and raw samples are preserved without smoothing or replacement.
        Any supplemental derived values remain separate and carry provenance.
        Provenance is recorded in JSON and relevant CSV columns.

        Metric settings:
        Moving threshold: \(detail.metricSettings.movingSpeedThresholdMetersPerSecond) m/s
        Route gap: \(detail.metricSettings.maximumRouteGap) s
        Maximum horizontal accuracy: \(detail.metricSettings.maximumHorizontalAccuracyMeters) m
        Limitations:
        HealthKit can return no accessible data when read permission is denied.
        Missing route or heart-rate data is exported as missing, never fabricated.
        Derived values may differ from Apple Fitness due to proprietary smoothing,
        calibration, sensor fusion, and pause handling.
        """
    }

    private nonisolated func update(
        _ phase: ExportProgress.Phase,
        index: Int,
        total: Int
    ) -> ExportProgress {
        ExportProgress(phase: phase, completedWorkouts: index, totalWorkouts: total)
    }
}
