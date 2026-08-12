import Foundation
import XCTest
@testable import WorkoutExporter

@MainActor
final class WorkoutMetadataStoreTests: XCTestCase {
    func testHistoryLocationTagsAndCachedExportsPersistIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let exportDirectory = root.appending(path: "Exports", directoryHint: .isDirectory)
        let metadataURL = root
            .appending(path: "Metadata", directoryHint: .isDirectory)
            .appending(path: "workout-metadata.json")
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = UUID()
        let secondID = UUID()
        let exportURL = exportDirectory.appending(path: "two-workouts.zip")
        try Data("export".utf8).write(to: exportURL)

        let store = WorkoutMetadataStore(
            persistenceURL: metadataURL,
            exportDirectory: exportDirectory
        )
        try store.setCustomLocationTag("  Mount Si  ", for: firstID)
        try store.recordExport(
            workoutIDs: [secondID, firstID, firstID],
            fileURL: exportURL
        )

        XCTAssertEqual(store.customLocationTag(for: firstID), "Mount Si")
        XCTAssertTrue(store.isExported(firstID))
        XCTAssertTrue(store.isExported(secondID))
        XCTAssertEqual(
            store.cachedExport(for: [secondID, firstID])?.url,
            exportURL
        )
        XCTAssertEqual(
            try metadataURL.deletingLastPathComponent().resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            true
        )

        try store.clearExportedFlag(for: [firstID])
        XCTAssertFalse(store.isExported(firstID))
        XCTAssertTrue(store.isExported(secondID))
        XCTAssertNotNil(store.cachedExport(for: [firstID, secondID]))

        let reloaded = WorkoutMetadataStore(
            persistenceURL: metadataURL,
            exportDirectory: exportDirectory
        )
        XCTAssertEqual(reloaded.customLocationTag(for: firstID), "Mount Si")
        XCTAssertFalse(reloaded.isExported(firstID))
        XCTAssertTrue(reloaded.isExported(secondID))
        XCTAssertEqual(
            reloaded.cachedExport(for: [firstID, secondID])?.url,
            exportURL
        )

        try FileManager.default.removeItem(at: exportURL)
        let pruned = WorkoutMetadataStore(
            persistenceURL: metadataURL,
            exportDirectory: exportDirectory
        )
        XCTAssertNil(pruned.cachedExport(for: [firstID, secondID]))
        XCTAssertTrue(pruned.cachedExports.isEmpty)
    }

    func testCustomLocationTagCanBeClearedAndIsLengthLimited() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkoutMetadataStore(
            persistenceURL: root.appending(path: "metadata.json"),
            exportDirectory: root
        )
        let workoutID = UUID()

        try store.setCustomLocationTag(String(repeating: "A", count: 150), for: workoutID)
        XCTAssertEqual(store.customLocationTag(for: workoutID)?.count, 120)

        try store.setCustomLocationTag("   ", for: workoutID)
        XCTAssertNil(store.customLocationTag(for: workoutID))
    }

    func testCachedExportRejectsFilesOutsideManagedTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let exports = root.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: exports,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appending(path: "outside.zip")
        try Data().write(to: outsideURL)
        let store = WorkoutMetadataStore(
            persistenceURL: root.appending(path: "metadata.json"),
            exportDirectory: exports
        )

        XCTAssertThrowsError(
            try store.recordExport(workoutIDs: [UUID()], fileURL: outsideURL)
        )
    }

    func testCachedExportRejectsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let exports = root.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: exports,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appending(path: "outside.zip")
        try Data().write(to: outsideURL)
        let linkURL = exports.appending(path: "linked.zip")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )
        let store = WorkoutMetadataStore(
            persistenceURL: root.appending(path: "metadata.json"),
            exportDirectory: exports
        )

        XCTAssertThrowsError(
            try store.recordExport(workoutIDs: [UUID()], fileURL: linkURL)
        )
    }

    func testPartialBatchMarksSuccessfulWorkoutsWithoutCachingPackage() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "partial.zip")
        try Data().write(to: package)
        let store = WorkoutMetadataStore(
            persistenceURL: root.appending(path: "metadata.json"),
            exportDirectory: root
        )
        let successfulID = UUID()

        try store.recordExport(
            workoutIDs: [successfulID],
            fileURL: package,
            cachePackage: false
        )

        XCTAssertTrue(store.isExported(successfulID))
        XCTAssertNil(store.cachedExport(for: [successfulID]))
    }

    func testCachedExportsAreScopedToExactExportOptions() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let basicURL = root.appending(path: "basic.csv")
        let detailedURL = root.appending(path: "detailed.zip")
        try Data("basic".utf8).write(to: basicURL)
        try Data("detailed".utf8).write(to: detailedURL)
        let store = WorkoutMetadataStore(
            persistenceURL: root.appending(path: "metadata.json"),
            exportDirectory: root
        )
        let workoutID = UUID()

        try store.recordExport(
            workoutIDs: [workoutID],
            fileURL: basicURL,
            cacheKey: "basic"
        )
        try store.recordExport(
            workoutIDs: [workoutID],
            fileURL: detailedURL,
            cacheKey: "detailed"
        )

        XCTAssertEqual(
            store.cachedExport(for: [workoutID], cacheKey: "basic")?.url,
            basicURL
        )
        XCTAssertEqual(
            store.cachedExport(for: [workoutID], cacheKey: "detailed")?.url,
            detailedURL
        )
        XCTAssertEqual(store.cachedExports.count, 2)
    }
}
