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
        let data = try WorkoutFileExporter().json(SyntheticWorkoutFactory.make(.cleanOutdoorRun))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaName"] as? String, "com.delphimon.workout-export")
        XCTAssertEqual(object["schemaVersion"] as? String, "1.0.0")
        let exportedAt = try XCTUnwrap(object["exportedAt"] as? String)
        XCTAssertTrue(exportedAt.contains("."))
    }

    func testGeneratedGPXAndTCXAreWellFormedXML() throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let exporter = WorkoutFileExporter()
        XCTAssertTrue(XMLValidator.validate(exporter.gpx(detail)))
        XCTAssertTrue(XMLValidator.validate(exporter.tcx(detail)))
    }

    func testCSVHasAllRequiredFilesAndCRLF() {
        let files = WorkoutFileExporter().csvFiles(SyntheticWorkoutFactory.make(.cleanOutdoorRun))
        XCTAssertEqual(Set(files.map(\.0)), ["samples.csv", "route.csv", "events.csv", "splits.csv", "statistics.csv"])
        XCTAssertTrue(files.allSatisfy { String(decoding: $0.1, as: UTF8.self).contains("\r\n") })
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
