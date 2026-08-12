import Darwin
import Foundation
import XCTest
@testable import WorkoutExporter

final class ExportTests: XCTestCase {
    func testCSVEscapingIsRFC4180Compatible() {
        XCTAssertEqual(ExportUtilities.csv("plain"), "plain")
        XCTAssertEqual(ExportUtilities.csv("a,b"), "\"a,b\"")
        XCTAssertEqual(ExportUtilities.csv("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(ExportUtilities.csv("a\nb"), "\"a\nb\"")
    }

    func testSpreadsheetCSVNeutralizesFormulaPrefixes() {
        XCTAssertEqual(
            ExportUtilities.spreadsheetSafeCSV("=HYPERLINK(\"bad\")"),
            "\"'=HYPERLINK(\"\"bad\"\")\""
        )
        XCTAssertEqual(ExportUtilities.spreadsheetSafeCSV("  +1"), "'  +1")
        XCTAssertEqual(ExportUtilities.spreadsheetSafeCSV("ordinary"), "ordinary")
    }

    func testMetadataAllowlistDropsUnknownObjectDescriptions() {
        let metadata = HealthKitMappings.safeMetadata([
            "safe": "value",
            "unknown": NSObject()
        ])

        XCTAssertEqual(metadata, ["safe": "value"])
    }

    func testFilenameIsSafeAndDeterministic() {
        var summary = SyntheticWorkoutFactory.make(.cleanOutdoorRun).summary
        summary.activityName = "Run / Trail: 5K 🚀"
        let first = ExportUtilities.safeFilename(for: summary)
        XCTAssertEqual(first, ExportUtilities.safeFilename(for: summary))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(":"))
        XCTAssertLessThanOrEqual(first.count, 255)
        let alternate = ExportUtilities.safeFilename(for: summary, format: .activityDateIdentifier)
        XCTAssertTrue(alternate.hasPrefix("run-trail-5k"))
        XCTAssertNotEqual(first, alternate)
    }

    func testJSONContainsVersionedSchemaAndFractionalTimestamps() throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let data = try WorkoutFileExporter().json(detail)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaName"] as? String, "com.delphimon.workout-export")
        XCTAssertEqual(object["schemaVersion"] as? String, "1.2.0")
        let exportedAt = try XCTUnwrap(object["exportedAt"] as? String)
        XCTAssertTrue(exportedAt.contains("."))
        let workout = try XCTUnwrap(object["workout"] as? [String: Any])
        let routes = try XCTUnwrap(workout["routes"] as? [String: Any])
        XCTAssertEqual(routes.count, 1)
        let routeID = try XCTUnwrap(detail.routes.keys.first)
        XCTAssertNotNil(routes[routeID.uuidString])
    }

    func testGeneratedGPXAndTCXAreWellFormedXML() throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let exporter = WorkoutFileExporter()
        XCTAssertTrue(XMLValidator.validate(try exporter.gpx(detail)))
        XCTAssertTrue(XMLValidator.validate(try exporter.tcx(detail)))
    }

    func testWorkoutDetailRoutesRoundTripAsJSONObject() throws {
        let detail = SyntheticWorkoutFactory.make(.multipleRouteSegments)
        let data = try JSONEncoder().encode(detail)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["routes"] as? [String: Any])?.count, detail.routes.count)

        let decoded = try JSONDecoder().decode(WorkoutDetail.self, from: data)
        XCTAssertEqual(decoded.routes, detail.routes)
    }

    func testCSVHasAllRequiredFilesAndCRLF() throws {
        let files = try WorkoutFileExporter().csvFiles(SyntheticWorkoutFactory.make(.cleanOutdoorRun))
        XCTAssertEqual(Set(files.map(\.0)), ["samples.csv", "route.csv", "events.csv", "splits.csv", "statistics.csv"])
        XCTAssertTrue(files.allSatisfy { String(decoding: $0.1, as: UTF8.self).contains("\r\n") })
    }

    func testPresetsUseOneNonredundantDefaultRepresentation() {
        let basic = ExportOptions.basic(unitScheme: .usCustomary)
        XCTAssertEqual(basic.formats, [.summary])
        XCTAssertFalse(basic.includeRawSamples)
        XCTAssertFalse(basic.includeDerivedMetrics)
        XCTAssertFalse(basic.packageAsZIP)
        XCTAssertEqual(basic.unitScheme, .usCustomary)

        let detailed = ExportOptions.detailed(unitScheme: .metric)
        XCTAssertEqual(detailed.formats, [.json, .gpx])
        XCTAssertTrue(detailed.includeRawSamples)
        XCTAssertTrue(detailed.includeDerivedMetrics)
        XCTAssertTrue(detailed.includeRoute)
        XCTAssertTrue(detailed.packageAsZIP)
        XCTAssertEqual(
            detailed.cacheKey,
            ExportOptions.detailed(unitScheme: .usCustomary).cacheKey
        )
        XCTAssertNotEqual(
            basic.cacheKey,
            ExportOptions.basic(unitScheme: .metric).cacheKey
        )
    }

    func testSummaryCSVUsesSelectedUnitsStableIDsAndLocationTags() throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.summary.totalDistanceMeters = 1_609.344
        detail.summary.elevationGainMeters = 304.8
        let original = detail.summary
        let record = WorkoutSummaryExportRecord(
            summary: detail.summary,
            locationTag: "=External formula",
            wasExported: false
        )

        let data = WorkoutSummaryCSVExporter.data(
            records: [record],
            unitScheme: .usCustomary
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix(WorkoutSummaryCSVExporter.columns.joined(separator: ",")))
        XCTAssertFalse(WorkoutSummaryCSVExporter.columns.contains("moving_time_s"))
        XCTAssertTrue(text.contains(detail.id.uuidString))
        XCTAssertTrue(text.contains("'=External formula"))
        XCTAssertTrue(text.contains(",1.0,mi,1000.0,ft,"))
        XCTAssertEqual(detail.summary, original)
    }

    func testBasicSummaryExportDoesNotLoadWorkoutDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let request = WorkoutExportRequest(
            id: detail.id,
            summary: detail.summary,
            locationTag: "Neighborhood",
            wasExported: false
        ) {
            throw WorkoutExporterError.queryFailure("Detail should not be loaded")
        }

        let result = try await ExportPackageBuilder().buildPackageResult(
            for: [request],
            options: .basic(unitScheme: .metric),
            to: root
        )

        XCTAssertEqual(result.exportedWorkoutIDs, [detail.id])
        XCTAssertEqual(result.url.pathExtension, "csv")
        let text = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(text.contains(detail.id.uuidString))
        XCTAssertTrue(text.contains("Neighborhood"))
    }

    func testSummaryOnlyExportHonorsHeartRateRouteAndSourceRedaction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.summary.averageHeartRateBPM = 199.25
        detail.summary.source.name = "Sensitive Source"
        detail.summary.source.bundleIdentifier = "com.example.sensitive"
        var options = ExportOptions.basic(unitScheme: .metric)
        options.includeHeartRate = false
        options.includeRoute = false
        options.includeSourceAndDevice = false

        let result = try await ExportPackageBuilder().buildPackageResult(
            for: [
                .loaded(
                    detail,
                    locationTag: "Sensitive Location"
                )
            ],
            options: options,
            to: root
        )
        let text = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertFalse(text.contains("199.25"))
        XCTAssertFalse(text.contains("Sensitive Source"))
        XCTAssertFalse(text.contains("com.example.sensitive"))
        XCTAssertFalse(text.contains("Sensitive Location"))
        XCTAssertTrue(text.contains("Redacted"))
    }

    func testDetailedPresetWritesJSONAndGPXWithoutDefaultCSVOrTCXDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        var options = ExportOptions.detailed(unitScheme: .metric)
        options.packageAsZIP = false

        let package = try await ExportPackageBuilder().buildPackage(
            for: [detail],
            options: options,
            to: root
        )
        let workoutFolder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: package,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        let filenames = Set(
            try FileManager.default.contentsOfDirectory(
                at: workoutFolder,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )

        XCTAssertTrue(filenames.contains("workout.json"))
        XCTAssertTrue(filenames.contains("route.gpx"))
        XCTAssertFalse(filenames.contains("samples.csv"))
        XCTAssertFalse(filenames.contains("workout.tcx"))
        let json = try String(
            contentsOf: workoutFolder.appending(path: "workout.json"),
            encoding: .utf8
        )
        XCTAssertTrue(json.contains("HKQuantityTypeIdentifierHeartRate"))
    }

    func testDetailedPresetOmitsEmptyGPXForWorkoutWithoutRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = ExportOptions.detailed(unitScheme: .metric)
        options.packageAsZIP = false

        let package = try await ExportPackageBuilder().buildPackage(
            for: [SyntheticWorkoutFactory.make(.noRoute)],
            options: options,
            to: root
        )
        let workoutFolder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: package,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workoutFolder.appending(path: "route.gpx").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workoutFolder.appending(path: "workout.json").path
            )
        )
    }

    func testHeartRateLookupReturnsNearestNativeSampleWithinTolerance() throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let sample = try XCTUnwrap(detail.heartRateSamples.first)
        let lookup = HeartRateLookup(samples: Array(detail.heartRateSamples.reversed()))

        XCTAssertEqual(lookup.value(nearestTo: sample.startDate.addingTimeInterval(1)), sample.value)
        XCTAssertNil(lookup.value(nearestTo: detail.summary.endDate.addingTimeInterval(60)))
    }

    func testCRC32MatchesStandardCheckValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xcbf4_3926)
    }

    func testStreamingSHA256MatchesInMemoryHash() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let content = Data(repeating: 0xa5, count: 200_000)
        try content.write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try ExportUtilities.sha256(fileAt: root)
        XCTAssertEqual(result.byteSize, content.count)
        XCTAssertEqual(result.digest, ExportUtilities.sha256(content))
    }

    func testPackageManifestChecksumsMatchFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = ExportOptions()
        options.packageAsZIP = false
        let package = try await ExportPackageBuilder().buildPackage(
            for: [SyntheticWorkoutFactory.make(.cleanOutdoorRun)],
            options: options,
            to: root
        )
        let workoutFolder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil).first
        )
        let manifestURL = workoutFolder.appending(path: "manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertEqual(Set(manifest.formats ?? []), options.formats)
        for entry in manifest.files {
            let content = try Data(contentsOf: workoutFolder.appending(path: entry.path))
            XCTAssertEqual(entry.byteSize, content.count)
            XCTAssertEqual(entry.sha256, ExportUtilities.sha256(content))
        }
    }

    func testGPXPreservesEveryRoutePointAndSeparatesRouteObjects() throws {
        let detail = SyntheticWorkoutFactory.make(.multipleRouteSegments)
        let xml = String(decoding: try WorkoutFileExporter().gpx(detail), as: UTF8.self)

        XCTAssertEqual(xml.components(separatedBy: "<trkseg>").count - 1, detail.routes.count)
        XCTAssertEqual(xml.components(separatedBy: "<trkpt ").count - 1, detail.routePoints.count)
        XCTAssertTrue(xml.contains("<gpxtpx:hr>"))
        XCTAssertTrue(xml.contains("<gpxtpx:speed>"))
    }

    func testBatchContinuesAfterOneWorkoutExportFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let failed = SyntheticWorkoutFactory.make(.hikeWithStops, index: 1)
        var options = ExportOptions()
        options.packageAsZIP = false
        options.formats = [.json]

        let result = try await ExportPackageBuilder(
            exporter: SelectiveFailingExporter(failedID: failed.id)
        ).buildPackageResult(
            for: [first, failed].map { WorkoutExportRequest.loaded($0) },
            options: options,
            to: root
        )
        let package = result.url

        XCTAssertEqual(result.exportedWorkoutIDs, [first.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appending(path: "export-warnings.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appending(path: "index.csv").path))
        let folders = try FileManager.default.contentsOfDirectory(
            at: package,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(folders.count, 1)
    }

    func testBatchContinuesWhenOneWorkoutCannotBeLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let failedID = UUID()
        var options = ExportOptions()
        options.packageAsZIP = false
        options.formats = [.json]

        let result = try await ExportPackageBuilder().buildPackageResult(
            for: [
                .loaded(first),
                WorkoutExportRequest(id: failedID) {
                    throw WorkoutExporterError.queryFailure("Synthetic expected load failure")
                }
            ],
            options: options,
            to: root
        )

        XCTAssertEqual(result.exportedWorkoutIDs, [first.id])
        let package = result.url
        let warning = try String(
            contentsOf: package.appending(path: "export-warnings.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(warning.contains(failedID.uuidString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appending(path: "index.csv").path))
    }

    func testZIPStartsWithLocalFileHeader() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ExportPackageBuilder().buildPackage(
            for: [SyntheticWorkoutFactory.make(.cleanOutdoorRun)],
            options: ExportOptions(),
            to: root
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
    }

    func testPackageReportsEveryExportPhase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ExportProgressRecorder()

        _ = try await ExportPackageBuilder().buildPackage(
            for: [SyntheticWorkoutFactory.make(.cleanOutdoorRun)],
            options: ExportOptions(),
            to: root
        ) { update in
            await recorder.append(update.phase)
        }

        let phases = await recorder.phases
        XCTAssertEqual(
            Set(phases),
            Set([.preparing, .json, .csv, .gpx, .tcx, .manifest, .archiving, .finalizing])
        )
    }

    func testPackageGenerationDoesNotRunExporterOnMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ThreadRecorder()
        var options = ExportOptions()
        options.packageAsZIP = false

        _ = try await ExportPackageBuilder(exporter: ThreadRecordingExporter(recorder: recorder)).buildPackage(
            for: [SyntheticWorkoutFactory.make(.cleanOutdoorRun)],
            options: options,
            to: root
        )

        let observations = await recorder.observations
        XCTAssertEqual(observations, [false])
    }

    func testCancelledPackageStopsAndRemovesStagingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await ExportPackageBuilder().buildPackage(
                for: [SyntheticWorkoutFactory.make(.veryLongWorkout)],
                options: ExportOptions(),
                to: root
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled export should not produce a package.")
        } catch let error as WorkoutExporterError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testExportOptionsRemoveExcludedSensitiveData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = ExportOptions()
        options.formats = [.json]
        options.packageAsZIP = false
        options.includeRawSamples = false
        options.includeRoute = false
        options.includeSourceAndDevice = false
        let package = try await ExportPackageBuilder().buildPackage(
            for: [SyntheticWorkoutFactory.make(.cleanOutdoorRun)],
            options: options,
            to: root
        )
        let workoutFolder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil).first
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: workoutFolder.appending(path: "workout.json"))) as? [String: Any]
        )
        let workout = try XCTUnwrap(object["workout"] as? [String: Any])
        XCTAssertEqual((workout["samples"] as? [Any])?.count, 0)
        XCTAssertEqual((workout["routes"] as? [String: Any])?.count, 0)
        let summary = try XCTUnwrap(workout["summary"] as? [String: Any])
        let source = try XCTUnwrap(summary["source"] as? [String: Any])
        XCTAssertEqual(source["name"] as? String, "Redacted")
    }

    func testHeartRateRedactionIsExhaustive() async throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.derived = try await WorkoutMetricCalculator().calculate(detail: detail)
        detail.metricSettings.heartRateZones.maximumHeartRateBPM = 205
        detail.metricSettings.heartRateZones.restingHeartRateBPM = 48
        XCTAssertFalse(detail.derived.splits.isEmpty)
        var options = ExportOptions()
        options.includeHeartRate = false

        let filtered = ExportPackageBuilder.filtered(detail, options: options)

        XCTAssertFalse(filtered.samples.contains {
            $0.typeIdentifier.localizedCaseInsensitiveContains("heartRate")
        })
        XCTAssertFalse(filtered.statistics.contains {
            $0.typeIdentifier.localizedCaseInsensitiveContains("heartRate")
        })
        XCTAssertNil(filtered.summary.averageHeartRateBPM)
        XCTAssertNil(filtered.derived.averageHeartRateBPM)
        XCTAssertNil(filtered.derived.minimumHeartRateBPM)
        XCTAssertNil(filtered.derived.maximumHeartRateBPM)
        XCTAssertNil(filtered.derived.heartRateZones)
        XCTAssertEqual(filtered.metricSettings.heartRateZones.maximumHeartRateBPM, 0)
        XCTAssertEqual(filtered.metricSettings.heartRateZones.restingHeartRateBPM, 0)
        XCTAssertFalse(
            filtered.metricSettings.heartRateZones
                .automaticallyEstimateMaximumHeartRate
        )
        XCTAssertTrue(filtered.metricSettings.heartRateZones.manualUpperBoundsBPM.isEmpty)
        XCTAssertTrue(filtered.derived.splits.allSatisfy {
            $0.averageHeartRateBPM == nil && $0.maximumHeartRateBPM == nil
        })
    }

    func testRouteRedactionRemovesCoordinatesAndDerivedRouteDataButPreservesNativeSummary() async throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.derived = try await WorkoutMetricCalculator().calculate(detail: detail)
        let nativeDistance = detail.summary.totalDistanceMeters
        let nativeGain = detail.summary.elevationGainMeters
        var options = ExportOptions()
        options.includeRoute = false

        let filtered = ExportPackageBuilder.filtered(detail, options: options)

        XCTAssertTrue(filtered.routes.isEmpty)
        XCTAssertFalse(filtered.summary.hasRoute)
        XCTAssertEqual(filtered.summary.totalDistanceMeters, nativeDistance)
        XCTAssertEqual(filtered.summary.elevationGainMeters, nativeGain)
        XCTAssertNil(filtered.derived.routeDistanceMeters)
        XCTAssertNil(filtered.derived.speedThresholdMovingTime)
        XCTAssertNil(filtered.derived.routeMetrics)
        XCTAssertNil(filtered.derived.elevationLossMeters)
        XCTAssertNil(filtered.derived.minimumAltitudeMeters)
        XCTAssertNil(filtered.derived.maximumAltitudeMeters)
        XCTAssertTrue(filtered.derived.splits.isEmpty)
    }

    func testSourceAndDeviceRedactionClearsEveryMetadataDictionary() {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.samples[0].metadata = ["secret": "sample"]
        detail.categorySamples = [
            CategorySample(
                id: UUID(),
                typeIdentifier: "category",
                startDate: detail.summary.startDate,
                endDate: detail.summary.endDate,
                value: 1,
                source: detail.summary.source,
                metadata: ["secret": "category"]
            )
        ]
        detail.events = [
            WorkoutEvent(
                id: UUID(),
                kind: .marker,
                startDate: detail.summary.startDate,
                metadata: ["secret": "event"]
            )
        ]
        detail.activities = [
            WorkoutActivitySegment(
                id: UUID(),
                activityIdentifier: detail.summary.activityIdentifier,
                activityName: detail.summary.activityName,
                startDate: detail.summary.startDate,
                endDate: detail.summary.endDate,
                metadata: ["secret": "activity"]
            )
        ]
        detail.metadata = ["secret": "workout"]
        var options = ExportOptions()
        options.includeSourceAndDevice = false

        let filtered = ExportPackageBuilder.filtered(detail, options: options)

        XCTAssertEqual(filtered.summary.source.name, "Redacted")
        XCTAssertNil(filtered.summary.device)
        XCTAssertTrue(filtered.metadata.isEmpty)
        XCTAssertTrue(filtered.samples.allSatisfy {
            $0.source.name == "Redacted" && $0.device == nil && $0.metadata.isEmpty
        })
        XCTAssertTrue(filtered.categorySamples.allSatisfy {
            $0.source.name == "Redacted" && $0.metadata.isEmpty
        })
        XCTAssertTrue(filtered.events.allSatisfy(\.metadata.isEmpty))
        XCTAssertTrue(filtered.activities.allSatisfy(\.metadata.isEmpty))
    }

    func testProtectedExportFilesUseCompleteProtection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try ExportUtilities.createProtectedDirectory(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "protected.json")
        try ExportUtilities.writeProtected(Data("{}".utf8), to: file)

        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS Simulator filesystem does not expose NSFileProtection attributes.")
        #elseif os(iOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }
}

private actor ExportProgressRecorder {
    private(set) var phases: [ExportProgress.Phase] = []

    func append(_ phase: ExportProgress.Phase) {
        phases.append(phase)
    }
}

private actor ThreadRecorder {
    private(set) var observations: [Bool] = []

    func append(_ value: Bool) {
        observations.append(value)
    }
}

private struct ThreadRecordingExporter: WorkoutExporting {
    let recorder: ThreadRecorder

    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL,
        progress: nonisolated(nonsending) @escaping @Sendable (ExportProgress.Phase) async -> Void
    ) async throws -> [URL] {
        let isMainThread = pthread_main_np() != 0
        await recorder.append(isMainThread)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return []
    }
}

private struct SelectiveFailingExporter: WorkoutExporting {
    let failedID: UUID

    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL,
        progress: nonisolated(nonsending) @escaping @Sendable (ExportProgress.Phase) async -> Void
    ) async throws -> [URL] {
        if detail.id == failedID {
            throw WorkoutExporterError.fileWriteFailure("Synthetic expected failure")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "workout.json")
        try Data("{}".utf8).write(to: output)
        return [output]
    }
}

private final class XMLValidator: NSObject, XMLParserDelegate {
    private var error: Error?

    static func validate(_ data: Data) -> Bool {
        let validator = XMLValidator()
        let parser = XMLParser(data: data)
        parser.delegate = validator
        return parser.parse() && validator.error == nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
