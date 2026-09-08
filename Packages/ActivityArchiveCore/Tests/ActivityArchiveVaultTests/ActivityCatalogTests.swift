import ActivityArchiveCore
import Foundation
import SQLite3
import XCTest

@testable import ActivityArchiveVault

final class ActivityCatalogTests: XCTestCase, @unchecked Sendable {
  func testTenThousandObservationPagingUsesStableIndexedOrderAndBoundedPages() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root)
    try seed(vault.layout.database, count: 10_000)
    let started = ContinuousClock.now
    let first = try await vault.database.catalogPage()
    let elapsed = started.duration(to: .now)
    print("CATALOG BENCHMARK 10000 observations, first 100-row page: \(elapsed)")
    XCTAssertLessThan(elapsed, .seconds(2))
    XCTAssertEqual(first.observations.count, 100)
    XCTAssertEqual(first.observations.first?.id, 10_000)
    var seen = Set(first.observations.map(\.id))
    var cursor = first.next
    while let next = cursor {
      let page = try await vault.database.catalogPage(after: next)
      XCTAssertLessThanOrEqual(page.observations.count, 100)
      for row in page.observations { XCTAssertTrue(seen.insert(row.id).inserted) }
      cursor = page.next
    }
    XCTAssertEqual(seen.count, 10_000)
    let oversized = try await vault.database.catalogPage(limit: Int.max)
    XCTAssertEqual(oversized.observations.count, 200)
    let plan = try sqlStrings(
      vault.layout.database,
      "EXPLAIN QUERY PLAN SELECT id FROM source_observations WHERE (COALESCE(start_date, imported_at), id) < (1000, 5000) ORDER BY COALESCE(start_date, imported_at) DESC, id DESC LIMIT 101",
      column: 3)
    XCTAssertTrue(plan.joined().contains("observations_catalog_order"))
    XCTAssertFalse(plan.joined().contains("TEMP B-TREE"))
  }

  func testLiteralSearchFiltersAndInvalidInputsDoNotAlterEvidence() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root)
    try seed(vault.layout.database, count: 20)
    var filter = ActivityCatalogFilter()
    filter.search = "%'; DROP TABLE source_observations; --"
    let injection = try await vault.database.catalogPage(filter: filter)
    XCTAssertTrue(injection.observations.isEmpty)
    filter.search = "_"
    let wildcard = try await vault.database.catalogPage(filter: filter)
    XCTAssertTrue(wildcard.observations.isEmpty)
    filter.search = "source:1"
    filter.source = "Fixture"
    filter.activityType = "Hiking"
    filter.routeState = "included"
    filter.metricsState = "unavailable"
    filter.completeness = "final"
    filter.from = Date(timeIntervalSince1970: 999)
    filter.through = Date(timeIntervalSince1970: 1001)
    let matches = try await vault.database.catalogPage(filter: filter)
    XCTAssertEqual(matches.observations.count, 11)
    filter.search = String(repeating: "a", count: 513)
    do {
      _ = try await vault.database.catalogPage(filter: filter)
      XCTFail("Expected bound")
    } catch {}
    filter.search = "x\0y"
    do {
      _ = try await vault.database.catalogPage(filter: filter)
      XCTFail("Expected null rejection")
    } catch {}
    let all = try await vault.database.catalogPage()
    XCTAssertEqual(all.observations.count, 20)
  }

  func testImportPagesWarningsStatusRecoveryAndNoLostEqualTimeJobs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "route.gpx")
    try Data("<gpx><trk><trkseg><trkpt lat=\"47\" lon=\"-122\"/></trkseg></trk></gpx>".utf8).write(
      to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    _ = try await vault.importArtifact(at: source)
    _ = try await vault.importArtifact(at: source)
    var filter = ActivityCatalogFilter()
    filter.hasWarnings = true
    let warned = try await vault.database.catalogPage(filter: filter)
    XCTAssertEqual(warned.observations.count, 1)
    filter.importStatus = .duplicate
    let duplicate = try await vault.database.catalogPage(filter: filter)
    XCTAssertEqual(duplicate.observations.count, 1)
    filter.hasWarnings = nil
    let jobs = try await vault.database.importPage(filter: filter)
    XCTAssertEqual(jobs.jobs.map(\.status), [.duplicate])
    let ids = (0..<205).map { _ in UUID() }
    for id in ids {
      try await vault.database.startImport(
        id: id, filename: "interrupted.gpx", sourcePath: nil, kind: .gpx,
        startedAt: Date(timeIntervalSince1970: 1000))
    }
    let recovered = try await vault.recoverInterruptedImports()
    XCTAssertEqual(recovered, 205)
    filter.importStatus = .rejected
    var cursor: ActivityImportCursor?
    var seen = Set<UUID>()
    repeat {
      let page = try await vault.database.importPage(filter: filter, after: cursor)
      for job in page.jobs { XCTAssertTrue(seen.insert(job.id).inserted) }
      cursor = page.next
    } while cursor != nil
    XCTAssertEqual(seen, Set(ids))
  }

  func testV1MigrationRetainsEvidenceAndAddsQueryIndexes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = ActivityVaultLayout(root: root)
    try layout.create()
    _ = try ActivityVaultDatabase(layout: layout)
    try seed(layout.database, count: 5)
    try sql(
      layout.database,
      """
      DROP INDEX observations_catalog_order; DROP INDEX observations_source_order;
      DROP INDEX observations_type_order; DROP INDEX jobs_catalog_order;
      DROP INDEX jobs_object_status; DROP INDEX warnings_job; DROP INDEX statistics_observation;
      DROP INDEX routes_observation; DROP INDEX jobs_observation_status; DROP INDEX observations_object;
      ALTER TABLE import_jobs DROP COLUMN observation_id; PRAGMA user_version = 1;
      """)
    let migrated = try ActivityVaultDatabase(layout: layout)
    let rows = try await migrated.catalogPage()
    XCTAssertEqual(
      rows.observations.map(\.sourceActivityID),
      ["source:5", "source:4", "source:3", "source:2", "source:1"])
    XCTAssertEqual(try sqlStrings(layout.database, "PRAGMA user_version", column: 0), ["2"])
  }

  func testCancelledCatalogAndIntegrityDoNotReportSuccess() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root)
    try seed(vault.layout.database, count: 100)
    let query = Task {
      try await Task.sleep(for: .milliseconds(20))
      return try await vault.database.catalogPage()
    }
    query.cancel()
    do {
      _ = try await query.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    let scan = Task { try await vault.integrityCheck() }
    scan.cancel()
    do {
      _ = try await scan.value
      XCTFail("Expected cancelled audit")
    } catch is CancellationError {}
  }

  func testIntegrityBoundsMissingSamplesAndRejectsSymlinkedShard() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"))
    try sql(
      vault.layout.database,
      """
      WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 250)
      INSERT INTO objects SELECT printf('%064x', x), 1, 1000 FROM n;
      """)
    let report = try await vault.integrityCheck()
    XCTAssertEqual(report.checkedObjects, 250)
    XCTAssertEqual(report.missingObjectCount, 250)
    XCTAssertEqual(report.missingObjects.count, 100)
    XCTAssertFalse(report.isHealthy)
    let outside = root.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: vault.layout.objects.appending(path: "00"), withDestinationURL: outside)
    do {
      _ = try await vault.objectStore.objectURL(for: String(repeating: "0", count: 64))
      XCTFail("Expected symlinked shard rejection")
    } catch let error as ActivityVaultError {
      guard case .unexpectedSymbolicLink = error else { return XCTFail("Unexpected error") }
    }
  }

  private func seed(_ database: URL, count: Int) throws {
    try sql(
      database,
      """
      INSERT INTO objects VALUES(printf('%064x', 1), 1, 1000);
      WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < \(count))
      INSERT INTO source_observations(package_id, package_revision, source_activity_id, content_hash,
        object_hash, kind, workout_type_name, title, start_date, source_name, completeness, route_state,
        metrics_state, metadata_json, imported_at)
      SELECT printf('00000000-0000-0000-0000-%012d', x), 1, 'source:'||x, printf('%064x', 1),
        printf('%064x', 1), 'gpx', 'Hiking', 'Test outing '||x, 1000, 'Fixture', 'final', 'included',
        'unavailable', CAST('{}' AS BLOB), 1000 FROM n;
      """)
  }

  private func sql(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      throw ActivityVaultError.database("fixture open")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw ActivityVaultError.database(String(cString: sqlite3_errmsg(db)))
    }
  }

  private func sqlStrings(_ url: URL, _ sql: String, column: Int32) throws -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      throw ActivityVaultError.database("fixture open")
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw ActivityVaultError.database("fixture query")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let text = sqlite3_column_text(statement, column) { rows.append(String(cString: text)) }
    }
    return rows
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "ActivityCatalogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
