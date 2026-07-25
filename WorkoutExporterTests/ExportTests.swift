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

    func testFilenameIsSafeAndDeterministic() {
        var summary = SyntheticWorkoutFactory.make(.cleanOutdoorRun).summary
        summary.activityName = "Run / Trail: 5K 🚀"
        let first = ExportUtilities.safeFilename(for: summary)
        XCTAssertEqual(first, ExportUtilities.safeFilename(for: summary))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(":"))
        XCTAssertLessThanOrEqual(first.count, 255)
    }

    func testJSONContainsVersionedSchemaAndFractionalTimestamps() throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let data = try WorkoutFileExporter().json(detail)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaName"] as? String, "com.delphimon.workout-export")
        XCTAssertEqual(object["schemaVersion"] as? String, "1.0.0")
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
        for entry in manifest.files {
            let content = try Data(contentsOf: workoutFolder.appending(path: entry.path))
            XCTAssertEqual(entry.byteSize, content.count)
            XCTAssertEqual(entry.sha256, ExportUtilities.sha256(content))
        }
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
