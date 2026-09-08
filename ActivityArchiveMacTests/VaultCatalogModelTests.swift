import ActivityArchiveVault
import Foundation
import XCTest

@testable import ActivityArchive

@MainActor
final class VaultCatalogModelTests: XCTestCase {
  func testSearchSelectionAndSourceDetailKeepTypeSeparateFromTitle() async throws {
    let (root, vault, id) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = VaultCatalogModel(vault: vault)
    await model.refresh(imports: false)
    XCTAssertEqual(model.activities.count, 1)
    await model.select(id)
    XCTAssertEqual(model.detail?.observation.workoutTypeName, "Imported Route")
    XCTAssertEqual(model.detail?.observation.title, "Fixture Trail")
    XCTAssertNil(model.detail?.deviceName)
    XCTAssertNil(model.route)
    model.filter.search = "no matching route"
    await model.refresh(imports: false)
    XCTAssertTrue(model.activities.isEmpty)
    XCTAssertFalse(model.isLoading)
  }

  func testSupersededQueryDoesNotPublishOldResults() async throws {
    let (root, vault, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = VaultCatalogModel(vault: vault)
    let old = Task { await model.refresh(imports: false) }
    await Task.yield()
    old.cancel()
    model.filter.search = "missing"
    await model.refresh(imports: false)
    await old.value
    XCTAssertTrue(model.activities.isEmpty)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isLoading)
  }

  func testLowDiskStateBlocksImportAndRecoveryIsActionable() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "CatalogCapacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = VaultCatalogModel(vault: try ActivityVault(rootURL: root, minimumFreeBytes: .max))
    await model.checkCapacity()
    XCTAssertTrue(model.isLowDisk)
    XCTAssertTrue(model.blocksImport)
    XCTAssertTrue(model.capacityMessage.contains("Free space"))
  }

  func testIntegrityMissingObjectPausesImportAndHealthyRetryRecovers() async throws {
    let (root, vault, id) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let detail = try await vault.database.observationDetail(id: id)
    let object = try await vault.objectStore.objectURL(for: detail.observation.objectHash)
    let bytes = try Data(contentsOf: object)
    try FileManager.default.removeItem(at: object)
    let model = VaultCatalogModel(vault: vault)
    model.checkIntegrity()
    try await waitForCheck(model)
    XCTAssertEqual(model.integrity?.missingObjectCount, 1)
    XCTAssertTrue(model.blocksImport)
    XCTAssertTrue(model.integrityMessage?.contains("Restore a verified backup") == true)
    _ = try await vault.objectStore.store(data: bytes)
    model.checkIntegrity()
    try await waitForCheck(model)
    XCTAssertEqual(model.integrity?.isHealthy, true)
    XCTAssertFalse(model.blocksImport)
  }

  func testCancelledRouteCannotReappearAfterSelectionIsCleared() async throws {
    let (root, vault, id) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = VaultCatalogModel(vault: vault)
    await model.select(id)
    model.loadRoute()
    await model.select(nil)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(model.route)
    XCTAssertNil(model.detail)
    XCTAssertFalse(model.isLoadingRoute)
  }

  private func waitForCheck(_ model: VaultCatalogModel) async throws {
    for _ in 0..<200 where model.isChecking { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isChecking)
  }

  private func fixture() async throws -> (URL, ActivityVault, Int64) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "CatalogModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "fixture.gpx")
    try Data(
      "<gpx><trk><name>Fixture Trail</name><trkseg><trkpt lat=\"47.123456789\" lon=\"-122\"/></trkseg></trk></gpx>"
        .utf8
    ).write(to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    let imported = try await vault.importArtifact(at: source)
    return (root, vault, try XCTUnwrap(imported.observationID))
  }
}
