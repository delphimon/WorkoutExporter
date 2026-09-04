import ActivityArchiveVault
import Foundation
import XCTest

@testable import ActivityArchive

@MainActor
final class VaultImportModelTests: XCTestCase {
  func testImportReportsImportedDuplicateAndFailureOutcomes() async throws {
    let access = AlwaysAllowedResourceAccess()
    let model = VaultImportModel(resourceAccess: access)
    let urls = [
      URL(fileURLWithPath: "/tmp/first.gpx"),
      URL(fileURLWithPath: "/tmp/duplicate.gpx"),
      URL(fileURLWithPath: "/tmp/broken.gpx"),
    ]
    let importer = OutcomeImporter()

    model.start(urls: urls, importer: importer)
    await waitUntilIdle(model)

    XCTAssertEqual(model.completedCount, 3)
    XCTAssertEqual(model.totalCount, 3)
    XCTAssertEqual(model.importedCount, 1)
    XCTAssertEqual(model.duplicateCount, 1)
    XCTAssertEqual(model.failures.map(\.filename), ["broken.gpx"])
    XCTAssertEqual(model.progress, 1)
    XCTAssertEqual(access.startedURLs, urls)
    XCTAssertEqual(access.stoppedURLs, urls)
  }

  func testCancellationStopsAWaitingImportAndClearsBusyState() async throws {
    let model = VaultImportModel(resourceAccess: AlwaysAllowedResourceAccess())
    let importer = WaitingImporter()
    model.start(urls: [URL(fileURLWithPath: "/tmp/slow.gpx")], importer: importer)
    await Task.yield()

    model.cancel()
    await waitUntilIdle(model)

    XCTAssertFalse(model.isImporting)
    XCTAssertNil(model.currentFilename)
    XCTAssertEqual(model.completedCount, 0)
    XCTAssertTrue(model.failures.isEmpty)
  }

  func testInaccessibleFileBecomesVisibleFailureWithoutCallingImporter() async {
    let access = AlwaysDeniedResourceAccess()
    let model = VaultImportModel(resourceAccess: access)
    let importer = OutcomeImporter()

    model.start(urls: [URL(fileURLWithPath: "/tmp/denied.gpx")], importer: importer)
    await waitUntilIdle(model)

    let callCount = await importer.callCount()
    XCTAssertEqual(model.completedCount, 1)
    XCTAssertEqual(model.failures.map(\.filename), ["denied.gpx"])
    XCTAssertEqual(callCount, 0)
  }

  private func waitUntilIdle(_ model: VaultImportModel) async {
    for _ in 0..<1_000 where model.isImporting {
      await Task.yield()
    }
    XCTAssertFalse(model.isImporting)
  }
}

private actor OutcomeImporter: ActivityArtifactImporting {
  private var calls = 0

  func importArtifact(at source: URL) async throws -> ActivityImportResult {
    calls += 1
    if source.lastPathComponent == "broken.gpx" {
      throw ActivityVaultError.invalidArtifact("Broken fixture")
    }
    let status: ActivityImportStatus =
      source.lastPathComponent == "duplicate.gpx" ? .duplicate : .imported
    return ActivityImportResult(
      jobID: UUID(),
      status: status,
      object: ActivityStoredObject(
        sha256: String(repeating: "a", count: 64),
        byteLength: 1,
        url: source,
        wasCreated: status == .imported
      ),
      observationID: 1
    )
  }

  func callCount() -> Int { calls }
}

private actor WaitingImporter: ActivityArtifactImporting {
  func importArtifact(at source: URL) async throws -> ActivityImportResult {
    try await Task.sleep(for: .seconds(30))
    throw CancellationError()
  }
}

private final class AlwaysAllowedResourceAccess:
  SecurityScopedResourceAccessing, @unchecked Sendable
{
  private(set) var startedURLs: [URL] = []
  private(set) var stoppedURLs: [URL] = []

  func start(url: URL) -> Bool {
    startedURLs.append(url)
    return true
  }

  func stop(url: URL) { stoppedURLs.append(url) }
}

private struct AlwaysDeniedResourceAccess: SecurityScopedResourceAccessing {
  func start(url: URL) -> Bool { false }
  func stop(url: URL) {}
}
