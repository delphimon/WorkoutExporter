import Foundation

actor ExportPackageBuilder: ExportPackageBuilding {
    private let exporter: any WorkoutExporting
    private let zipWriter: ZIPArchiveWriter
    private let activityPackageAdapter: ActivityPackageWorkoutAdapter

    init(
        exporter: any WorkoutExporting = WorkoutFileExporter(),
        zipWriter: ZIPArchiveWriter = ZIPArchiveWriter(),
        activityPackageAdapter: ActivityPackageWorkoutAdapter = ActivityPackageWorkoutAdapter()
    ) {
        self.exporter = exporter
        self.zipWriter = zipWriter
        self.activityPackageAdapter = activityPackageAdapter
    }

    func buildPackageResult(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> ExportPackageResult {
        do {
            guard !requests.isEmpty else { throw WorkoutExporterError.noAccessibleData }
            if options.formats == [.activityPackage] {
                return try await buildActivityPackages(
                    for: requests,
                    options: options,
                    to: directory,
                    progress: progress
                )
            }
            if options.formats.contains(.activityPackage) {
                throw WorkoutExporterError.encodingFailure(
                    "Activity Package is already a complete export. Select it by itself, or choose legacy formats instead."
                )
            }
            if options.formats == [.summary] {
                return try await buildSummaryOnlyPackage(
                    for: requests,
                    options: options,
                    to: directory,
                    progress: progress
                )
            }
            let staging = directory.appending(path: "WorkoutExporter-\(UUID().uuidString)", directoryHint: .isDirectory)
            try ExportUtilities.createProtectedDirectory(at: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            var completedWorkouts: [WorkoutSummaryExportRecord] = []
            var failures: [String] = []
            let detailedFormats = options.formats.subtracting([.summary])

            for (index, request) in requests.enumerated() {
                try Task.checkCancellation()
                await progress(update(.preparing, index: index, total: requests.count))
                var workoutFolder: URL?
                do {
                    let workout = try await request.load()
                    let preparedWorkout = Self.filtered(workout, options: options)
                    let folderName = ExportUtilities.safeFilename(
                        for: preparedWorkout.summary,
                        format: options.filenameFormat
                    )
                    let destinationFolder = staging.appending(path: folderName, directoryHint: .isDirectory)
                    workoutFolder = destinationFolder
                    let writtenFiles = try await exporter.export(
                        preparedWorkout,
                        formats: detailedFormats,
                        to: destinationFolder
                    ) { phase in
                        await progress(self.update(phase, index: index, total: requests.count))
                    }
                    let emittedFormats = emittedFormats(
                        requested: detailedFormats,
                        writtenFiles: writtenFiles
                    )
                    let readme = packageReadme(
                        preparedWorkout,
                        options: options,
                        emittedFormats: emittedFormats
                    )
                    try ExportUtilities.writeProtected(
                        Data(readme.utf8),
                        to: destinationFolder.appending(path: "README.txt")
                    )
                    await progress(update(.manifest, index: index, total: requests.count))
                    let manifest = try manifest(
                        for: destinationFolder,
                        warnings: preparedWorkout.warnings,
                        formats: emittedFormats
                    )
                    try ExportUtilities.writeProtected(
                        encoded(manifest),
                        to: destinationFolder.appending(path: "manifest.json")
                    )
                    completedWorkouts.append(
                        WorkoutSummaryExportRecord(
                            summary: preparedWorkout.summary,
                            locationTag: options.includeRoute ? request.locationTag : nil,
                            wasExported: request.wasExported
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkoutExporterError where error == .cancelled {
                    throw error
                } catch {
                    if let workoutFolder {
                        try? FileManager.default.removeItem(at: workoutFolder)
                    }
                    failures.append(
                        "Workout \(request.id.uuidString): \(error.localizedDescription)"
                    )
                    await progress(update(.partialFailure, index: index, total: requests.count))
                    if requests.count == 1 { throw error }
                }
                if index.isMultiple(of: 4) { await Task.yield() }
            }
            guard !completedWorkouts.isEmpty else {
                throw WorkoutExporterError.fileWriteFailure(
                    failures.joined(separator: "\n")
                )
            }
            if options.formats.contains(.summary) {
                await progress(update(.summary, index: requests.count - 1, total: requests.count))
                try ExportUtilities.writeProtected(
                    WorkoutSummaryCSVExporter.data(
                        records: completedWorkouts,
                        unitScheme: options.unitScheme
                    ),
                    to: staging.appending(path: "workouts.csv")
                )
            }
            if !failures.isEmpty {
                let report = (
                    ["Some selected workouts could not be exported. Completed workouts remain usable.", ""]
                        + failures
                ).joined(separator: "\n")
                try ExportUtilities.writeProtected(
                    Data(report.utf8),
                    to: staging.appending(path: "export-warnings.txt")
                )
            }

            if completedWorkouts.count > 1 || !failures.isEmpty {
                let index = completedWorkouts.map {
                    "\(ExportUtilities.safeFilename(for: $0.summary, format: options.filenameFormat)),\($0.summary.id.uuidString),\(ExportUtilities.date($0.summary.startDate)),\(ExportUtilities.spreadsheetSafeCSV($0.summary.activityName))"
                }
                let text = (["folder,workout_id,start_time,activity"] + index).joined(separator: "\r\n") + "\r\n"
                try ExportUtilities.writeProtected(Data(text.utf8), to: staging.appending(path: "index.csv"))
            }

            let packageName = completedWorkouts.count == 1 && requests.count == 1
                ? ExportUtilities.safeFilename(
                    for: completedWorkouts[0].summary,
                    format: options.filenameFormat
                )
                : "workout-export-\(ExportUtilities.date(Date()).prefix(10))-\(completedWorkouts.count)-workouts"
            if options.packageAsZIP {
                await progress(update(.archiving, index: requests.count - 1, total: requests.count))
                let destination = directory.appending(path: "\(packageName).zip")
                let files = try recursiveFiles(in: staging).map { url -> (String, URL) in
                    let relative = url.path.replacingOccurrences(of: staging.path + "/", with: "")
                    return (relative, url)
                }
                try zipWriter.write(files: files, to: destination)
                await progress(update(.finalizing, index: requests.count - 1, total: requests.count))
                return ExportPackageResult(
                    url: destination,
                    exportedWorkoutIDs: Set(completedWorkouts.map(\.summary.id))
                )
            }

            await progress(update(.finalizing, index: requests.count - 1, total: requests.count))
            let destination = directory.appending(path: packageName, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: staging, to: destination)
            try ExportUtilities.applyCompleteFileProtectionRecursively(to: destination)
            return ExportPackageResult(
                url: destination,
                exportedWorkoutIDs: Set(completedWorkouts.map(\.summary.id))
            )
        } catch is CancellationError {
            throw WorkoutExporterError.cancelled
        } catch let error as WorkoutExporterError {
            throw error
        } catch {
            throw WorkoutExporterError.fileWriteFailure(error.localizedDescription)
        }
    }

    private func buildActivityPackages(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> ExportPackageResult {
        let staging = directory.appending(
            path: "ActivityManager-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try ExportUtilities.createProtectedDirectory(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }

        var completed: [(id: UUID, url: URL)] = []
        var failures: [String] = []
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            await progress(update(.preparing, index: index, total: requests.count))
            do {
                let detail = Self.filtered(try await request.load(), options: options)
                let filename = ExportUtilities.safeFilename(
                    for: detail.summary,
                    format: options.filenameFormat
                )
                let destination = staging.appending(path: "\(filename).activitypkg")
                await progress(update(.activityPackage, index: index, total: requests.count))
                try activityPackageAdapter.write(
                    detail,
                    locationTag: options.includeRoute ? request.locationTag : nil,
                    options: options,
                    to: destination
                )
                completed.append((request.id, destination))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WorkoutExporterError where error == .cancelled {
                throw error
            } catch {
                failures.append("Workout \(request.id.uuidString): \(error.localizedDescription)")
                await progress(update(.partialFailure, index: index, total: requests.count))
                if requests.count == 1 { throw error }
            }
            if index.isMultiple(of: 4) { await Task.yield() }
        }

        guard !completed.isEmpty else {
            throw WorkoutExporterError.fileWriteFailure(failures.joined(separator: "\n"))
        }

        await progress(update(.finalizing, index: requests.count - 1, total: requests.count))
        if completed.count == 1, failures.isEmpty {
            let destination = directory.appending(path: completed[0].url.lastPathComponent)
            try replaceItem(at: destination, with: completed[0].url)
            try ExportUtilities.applyCompleteFileProtection(to: destination)
            return ExportPackageResult(
                url: destination,
                exportedWorkoutIDs: [completed[0].id]
            )
        }

        if !failures.isEmpty {
            let report = (
                ["Some selected workouts could not be exported. Completed Activity Packages remain usable.", ""]
                    + failures
            ).joined(separator: "\n")
            try ExportUtilities.writeProtected(
                Data(report.utf8),
                to: staging.appending(path: "export-warnings.txt")
            )
        }
        await progress(update(.archiving, index: requests.count - 1, total: requests.count))
        let packageName = "activity-packages-\(ExportUtilities.date(Date()).prefix(10))-\(completed.count)-workouts.zip"
        let destination = directory.appending(path: packageName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let files = try recursiveFiles(in: staging).map { url -> (String, URL) in
            let relative = url.path.replacingOccurrences(of: staging.path + "/", with: "")
            return (relative, url)
        }
        try zipWriter.write(files: files, to: destination)
        try ExportUtilities.applyCompleteFileProtection(to: destination)
        return ExportPackageResult(
            url: destination,
            exportedWorkoutIDs: Set(completed.map(\.id))
        )
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func buildSummaryOnlyPackage(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> ExportPackageResult {
        var records: [WorkoutSummaryExportRecord] = []
        records.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            await progress(update(.preparing, index: index, total: requests.count))
            let summary: WorkoutSummary
            if let existingSummary = request.summary {
                summary = existingSummary
            } else {
                let detail = try await request.load()
                summary = detail.summary
            }
            records.append(
                WorkoutSummaryExportRecord(
                    summary: Self.filteredSummary(summary, options: options),
                    locationTag: options.includeRoute ? request.locationTag : nil,
                    wasExported: request.wasExported
                )
            )
        }

        await progress(update(.summary, index: requests.count - 1, total: requests.count))
        let data = WorkoutSummaryCSVExporter.data(
            records: records,
            unitScheme: options.unitScheme
        )
        let baseName = "workout-summary-\(ExportUtilities.date(Date()).prefix(10))-\(records.count)-workouts"
        let destination: URL
        if options.packageAsZIP {
            let staging = directory.appending(
                path: "WorkoutExporter-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try ExportUtilities.createProtectedDirectory(at: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            let csv = staging.appending(path: "workouts.csv")
            try ExportUtilities.writeProtected(data, to: csv)
            await progress(update(.archiving, index: requests.count - 1, total: requests.count))
            destination = directory.appending(path: "\(baseName).zip")
            try zipWriter.write(files: [("workouts.csv", csv)], to: destination)
        } else {
            destination = directory.appending(path: "\(baseName).csv")
            try ExportUtilities.writeProtected(data, to: destination)
        }
        await progress(update(.finalizing, index: requests.count - 1, total: requests.count))
        return ExportPackageResult(
            url: destination,
            exportedWorkoutIDs: Set(records.map(\.summary.id))
        )
    }

    nonisolated static func filtered(_ workout: WorkoutDetail, options: ExportOptions) -> WorkoutDetail {
        var result = workout
        if !options.includeRawSamples {
            result.samples = []
            result.categorySamples = []
        }
        if !options.includeHeartRate {
            result.samples.removeAll { isHeartRateIdentifier($0.typeIdentifier) }
            result.statistics.removeAll { isHeartRateIdentifier($0.typeIdentifier) }
            result.summary.averageHeartRateBPM = nil
            result.derived.averageHeartRateBPM = nil
            result.derived.minimumHeartRateBPM = nil
            result.derived.maximumHeartRateBPM = nil
            result.derived.heartRateZones = nil
            result.metricSettings.heartRateZones = HeartRateZoneSettings(
                method: .manual,
                automaticallyEstimateMaximumHeartRate: false,
                maximumHeartRateBPM: 0,
                restingHeartRateBPM: 0,
                manualUpperBoundsBPM: []
            )
            result.derived.splits = result.derived.splits.map { split in
                var split = split
                split.averageHeartRateBPM = nil
                split.maximumHeartRateBPM = nil
                return split
            }
            result.warnings.removeAll {
                $0.localizedCaseInsensitiveContains("heart-rate")
                    || $0.localizedCaseInsensitiveContains("heart rate")
            }
            result.derived.warnings.removeAll {
                $0.localizedCaseInsensitiveContains("heart-rate")
                    || $0.localizedCaseInsensitiveContains("heart rate")
            }
        }
        if !options.includeRoute {
            result.routes = [:]
            result.summary.hasRoute = false
            result.derived.routeDistanceMeters = nil
            result.derived.speedThresholdMovingTime = nil
            if result.derived.averageSpeedMetersPerSecond?.provenance == .routeDerived {
                result.derived.averageSpeedMetersPerSecond = nil
            }
            if result.derived.maximumSpeedMetersPerSecond?.provenance == .routeDerived {
                result.derived.maximumSpeedMetersPerSecond = nil
            }
            result.derived.routeMetrics = nil
            result.derived.elevationLossMeters = nil
            result.derived.minimumAltitudeMeters = nil
            result.derived.maximumAltitudeMeters = nil
            result.derived.splits = []
            result.warnings.removeAll {
                $0.localizedCaseInsensitiveContains("route")
                    || $0.localizedCaseInsensitiveContains("GPS")
            }
            result.derived.warnings.removeAll {
                $0.localizedCaseInsensitiveContains("route")
                    || $0.localizedCaseInsensitiveContains("GPS")
            }
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
                sample.metadata = [:]
                return sample
            }
            result.categorySamples = result.categorySamples.map { sample in
                var sample = sample
                sample.source = redacted
                sample.metadata = [:]
                return sample
            }
            result.events = result.events.map { event in
                var event = event
                event.metadata = [:]
                return event
            }
            result.activities = result.activities.map { activity in
                var activity = activity
                activity.metadata = [:]
                return activity
            }
            result.metadata = [:]
        }
        return result
    }

    private nonisolated static func filteredSummary(
        _ summary: WorkoutSummary,
        options: ExportOptions
    ) -> WorkoutSummary {
        var result = summary
        if !options.includeHeartRate {
            result.averageHeartRateBPM = nil
        }
        if !options.includeRoute {
            result.hasRoute = false
        }
        if !options.includeSourceAndDevice {
            result.source = SourceInfo(
                name: "Redacted",
                bundleIdentifier: "",
                version: nil,
                operatingSystemVersion: nil
            )
            result.device = nil
        }
        return result
    }

    private nonisolated static func isHeartRateIdentifier(_ identifier: String) -> Bool {
        identifier.localizedCaseInsensitiveContains("HeartRate")
    }

    private func manifest(
        for directory: URL,
        warnings: [String],
        formats: Set<ExportFormat>
    ) throws -> ExportManifest {
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
            warnings: warnings,
            formats: formats.sorted { $0.rawValue < $1.rawValue }
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
        case "activitypkg": "application/vnd.activityarchive.package+zip"
        case "json": "application/json"
        case "csv": "text/csv"
        case "gpx": "application/gpx+xml"
        case "tcx": "application/vnd.garmin.tcx+xml"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    private func emittedFormats(
        requested: Set<ExportFormat>,
        writtenFiles: [URL]
    ) -> Set<ExportFormat> {
        let names = Set(writtenFiles.map(\.lastPathComponent))
        return Set(requested.filter { format in
            switch format {
            case .summary: names.contains("workouts.csv")
            case .activityPackage: names.contains { $0.hasSuffix(".activitypkg") }
            case .json: names.contains("workout.json")
            case .csv: names.contains { $0.hasSuffix(".csv") }
            case .gpx: names.contains("route.gpx")
            case .tcx: names.contains("workout.tcx")
            }
        })
    }

    private func packageReadme(
        _ detail: WorkoutDetail,
        options: ExportOptions,
        emittedFormats: Set<ExportFormat>
    ) -> String {
        """
        Activity Manager package
        Schema: com.delphimon.workout-export \(ExportSchema.version)
        Workout: \(detail.summary.activityName) at \(ExportUtilities.date(detail.summary.startDate))

        Timestamps use ISO 8601 with fractional-second precision and an explicit UTC offset.
        Canonical distance, altitude, and speed values use meters, meters, and meters/second.
        HealthKit workout statistics and raw samples are preserved without smoothing or replacement.
        Any supplemental derived values remain separate and carry provenance.
        Provenance is recorded in JSON and relevant CSV columns.
        Included formats: \(emittedFormats.map(\.displayName).sorted().joined(separator: ", "))
        Summary CSV units: \(options.unitScheme.label)

        Metric settings:
        Moving threshold: \(detail.metricSettings.movingSpeedThresholdMetersPerSecond) m/s
        Minimum moving duration: \(detail.metricSettings.minimumMovingDuration) s
        Minimum stopped duration: \(detail.metricSettings.minimumStoppedDuration) s
        Route gap: \(detail.metricSettings.maximumRouteGap) s
        Maximum horizontal accuracy: \(detail.metricSettings.maximumHorizontalAccuracyMeters) m
        Split mode: \(detail.metricSettings.splitMode.rawValue)
        Split distance: \(detail.metricSettings.splitDistanceMeters) m
        Split elapsed interval: \(detail.metricSettings.splitElapsedTime) s
        Heart-rate zone method: \(detail.metricSettings.heartRateZones.method.rawValue)
        Heart-rate maximum: \(detail.metricSettings.heartRateZones.maximumHeartRateBPM) bpm
        Limitations:
        HealthKit can return no accessible data when read permission is denied.
        Missing route or heart-rate data is exported as missing, never fabricated.
        Derived values may differ from Apple Fitness due to proprietary
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
