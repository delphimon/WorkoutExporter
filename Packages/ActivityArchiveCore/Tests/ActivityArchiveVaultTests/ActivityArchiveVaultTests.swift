import ActivityArchiveCore
import Foundation
import SQLite3
import XCTest

@testable import ActivityArchiveVault

@MainActor
final class ActivityArchiveVaultTests: XCTestCase {
  func testLayoutCreatesPrivateExpectedDirectoriesAndRejectsSymlinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appending(path: "vault", directoryHint: .isDirectory)
    let layout = ActivityVaultLayout(root: vaultRoot)

    try layout.create()
    try layout.validate()

    for directory in layout.managedDirectories {
      var isDirectory: ObjCBool = false
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
      XCTAssertTrue(isDirectory.boolValue)
      let permissions = try permissions(at: directory)
      XCTAssertEqual(permissions & 0o077, 0)
    }

    let unsafeRoot = root.appending(path: "unsafe", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: unsafeRoot.appending(path: "objects"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: unsafeRoot.appending(path: "objects/sha256"),
      withDestinationURL: outside
    )

    XCTAssertThrowsError(try ActivityVaultLayout(root: unsafeRoot).create()) { error in
      guard case ActivityVaultError.unexpectedSymbolicLink = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testObjectStoreIsImmutableExactAndIdempotent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = ActivityVaultLayout(root: root.appending(path: "vault"))
    try layout.create()
    let store = ActivityObjectStore(layout: layout)
    let bytes = Data([0, 1, 2, 3, 255, 10, 13])

    let first = try await store.store(data: bytes)
    let second = try await store.store(data: bytes)
    let different = try await store.store(data: Data("different".utf8))

    XCTAssertTrue(first.wasCreated)
    XCTAssertFalse(second.wasCreated)
    XCTAssertEqual(first.sha256, second.sha256)
    XCTAssertNotEqual(first.sha256, different.sha256)
    XCTAssertEqual(try Data(contentsOf: first.url), bytes)
    XCTAssertEqual(try permissions(at: first.url) & 0o222, 0)
    let isVerified = try await store.verify(hash: first.sha256)
    XCTAssertTrue(isVerified)
    let objectDirectory = first.url.deletingLastPathComponent()
    let objectFiles = try FileManager.default.contentsOfDirectory(
      at: objectDirectory,
      includingPropertiesForKeys: nil
    )
    XCTAssertFalse(objectFiles.contains { $0.lastPathComponent.hasSuffix(".partial") })
    do {
      _ = try await store.objectURL(for: String(repeating: "é", count: 64))
      XCTFail("Expected a non-ASCII object hash to be rejected")
    } catch let error as ActivityVaultError {
      guard case .invalidVault = error else { return XCTFail("Unexpected error: \(error)") }
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.url.path)
    try Data(repeating: 7, count: bytes.count).write(to: first.url)
    do {
      _ = try await store.store(data: bytes)
      XCTFail("Expected an existing-object collision check to fail")
    } catch let error as ActivityVaultError {
      guard case .objectHashMismatch = error else { return XCTFail("Unexpected error: \(error)") }
    }

    try FileManager.default.removeItem(at: first.url)
    let external = root.appending(path: "external-object")
    try bytes.write(to: external)
    try FileManager.default.createSymbolicLink(at: first.url, withDestinationURL: external)
    do {
      _ = try await store.verify(hash: first.sha256)
      XCTFail("Expected an object symbolic link to be rejected")
    } catch let error as ActivityVaultError {
      guard case .unexpectedSymbolicLink = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testActivityPackageImportPreservesExactSourceValuesAndDeduplicates() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(path: "hike.activitypkg")
    let sourceBytes = Data("vendor-extension=keep-exactly\n".utf8)
    let manifest = try makePackage(
      at: package,
      distance: 13.987_654_321,
      payload: sourceBytes
    )
    let originalBytes = try Data(contentsOf: package)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    XCTAssertEqual(try permissions(at: vault.layout.database) & 0o077, 0)

    let first = try await vault.importArtifact(at: package)
    let second = try await vault.importArtifact(at: package)

    XCTAssertEqual(first.status, .imported)
    XCTAssertEqual(second.status, .duplicate)
    XCTAssertEqual(first.observationID, second.observationID)
    XCTAssertEqual(try Data(contentsOf: first.object.url), originalBytes)
    let observations = try await vault.database.observations()
    XCTAssertEqual(observations.count, 1)
    XCTAssertEqual(observations[0].packageID, manifest.packageID)
    XCTAssertEqual(observations[0].workoutTypeIdentifier, 37)
    XCTAssertEqual(observations[0].workoutTypeName, "Hiking")
    XCTAssertEqual(observations[0].title, "Enchantments")
    XCTAssertEqual(observations[0].completeness, "final")
    XCTAssertEqual(observations[0].timeZoneIdentifier, "America/Los_Angeles")
    let statistics = try await vault.database.sourceStatistics(observationID: observations[0].id)
    XCTAssertEqual(statistics.count, 2)
    XCTAssertEqual(statistics[0].value, 13.987_654_321)
    XCTAssertEqual(statistics[0].unit, "mi")
    XCTAssertEqual(statistics[1].value, 9_415.75)
    XCTAssertEqual(statistics[1].unit, "ft")
    let objectHashes = try await vault.database.objectHashes()
    XCTAssertEqual(objectHashes, [first.object.sha256])
    let integrity = try await vault.integrityCheck()
    XCTAssertTrue(integrity.isHealthy)
  }

  func testReceiptFailureDoesNotRollBackCommittedImport() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "route.geojson")
    try geoJSON(name: "Walk", longitude: -122).write(to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: vault.layout.processed.path
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: vault.layout.processed.path
      )
    }

    let result = try await vault.importArtifact(at: source)
    let jobs = try await vault.database.importJobs()
    let warnings = try await vault.database.warnings(jobID: result.jobID)
    let observations = try await vault.database.observations()

    XCTAssertEqual(result.status, .imported)
    XCTAssertEqual(jobs.first?.status, .imported)
    XCTAssertTrue(warnings.map(\.code).contains("receipt-write-failed"))
    XCTAssertEqual(observations.count, 1)
  }

  func testConflictingImmutableRevisionIsRejectedButOriginalObjectIsRetained() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appending(path: "first.activitypkg")
    let secondURL = root.appending(path: "second.activitypkg")
    _ = try makePackage(at: firstURL, distance: 10, payload: Data("one".utf8))
    _ = try makePackage(at: secondURL, distance: 11, payload: Data("two".utf8))
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    _ = try await vault.importArtifact(at: firstURL)

    do {
      _ = try await vault.importArtifact(at: secondURL)
      XCTFail("Expected an immutable revision conflict")
    } catch let error as ActivityVaultError {
      guard case .revisionConflict = error else { return XCTFail("Unexpected error: \(error)") }
    }

    let observations = try await vault.database.observations()
    let objectHashes = try await vault.database.objectHashes()
    XCTAssertEqual(observations.count, 1)
    XCTAssertEqual(objectHashes.count, 2)
    let jobs = try await vault.database.importJobs()
    XCTAssertEqual(jobs.first?.status, .rejected)
    XCTAssertNotNil(jobs.first?.contentHash)
    let integrity = try await vault.integrityCheck()
    XCTAssertTrue(integrity.isHealthy)
  }

  func testGPXImportIndexesBoundsTimesAndPreservesExactBytes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "route.gpx")
    let bytes = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1"><metadata><time>2020-01-01T00:00:00Z</time></metadata>
      <trk><name>Enchantments Traverse</name><trkseg>
      <trkpt lat="47.40" lon="-120.90"><time>2026-07-29T12:00:00.000Z</time></trkpt>
      <trkpt lat="47.55" lon="-120.70"><time>2026-07-29T13:30:00Z</time></trkpt>
      </trkseg></trk></gpx>
      """.utf8
    )
    try bytes.write(to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)

    let result = try await vault.importArtifact(at: source)
    let observations = try await vault.database.observations()
    let observation = try XCTUnwrap(observations.first)
    let routes = try await vault.database.routeSummaries(observationID: observation.id)
    let route = try XCTUnwrap(routes.first)

    XCTAssertEqual(result.status, .imported)
    XCTAssertEqual(try Data(contentsOf: result.object.url), bytes)
    XCTAssertEqual(observation.workoutTypeName, "Imported Route")
    XCTAssertEqual(observation.title, "Enchantments Traverse")
    XCTAssertEqual(observation.durationSeconds, 5_400)
    XCTAssertEqual(route.pointCount, 2)
    XCTAssertEqual(route.minimumLatitude, 47.40)
    XCTAssertEqual(route.maximumLatitude, 47.55)
    XCTAssertEqual(route.minimumLongitude, -120.90)
    XCTAssertEqual(route.maximumLongitude, -120.70)
    XCTAssertTrue(route.hasTimestamps)
  }

  func testGeoJSONImportIndexesLineGeometryAndKeepsUnknownFieldsInOriginal() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "route.geojson")
    let bytes = Data(
      """
      {"type":"FeatureCollection","vendor":{"opaque":[1,2,3]},"features":[
        {"type":"Feature","properties":{"name":"Neighborhood Walk","foreign":"kept"},
         "geometry":{"type":"LineString","coordinates":[[-122.4,47.6],[-122.2,47.8]]}}
      ]}
      """.utf8
    )
    try bytes.write(to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)

    let result = try await vault.importArtifact(at: source)
    let observations = try await vault.database.observations()
    let observation = try XCTUnwrap(observations.first)
    let routes = try await vault.database.routeSummaries(observationID: observation.id)
    let route = try XCTUnwrap(routes.first)

    XCTAssertEqual(try Data(contentsOf: result.object.url), bytes)
    XCTAssertEqual(observation.workoutTypeName, "Imported Route")
    XCTAssertEqual(observation.title, "Neighborhood Walk")
    XCTAssertEqual(route.pointCount, 2)
    XCTAssertEqual(route.minimumLongitude, -122.4)
    XCTAssertEqual(route.maximumLatitude, 47.8)
  }

  func testMalformedArtifactIsRejectedWithReceiptAndRetainedOriginal() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "broken.gpx")
    try Data("<gpx><trk>not closed".utf8).write(to: source)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)

    do {
      _ = try await vault.importArtifact(at: source)
      XCTFail("Expected malformed GPX rejection")
    } catch let error as ActivityVaultError {
      guard case .invalidArtifact = error else { return XCTFail("Unexpected error: \(error)") }
    }

    let jobs = try await vault.database.importJobs()
    let job = try XCTUnwrap(jobs.first)
    XCTAssertEqual(job.status, .rejected)
    XCTAssertNotNil(job.contentHash)
    let contentHash = try XCTUnwrap(job.contentHash)
    let objectHashes = try await vault.database.objectHashes()
    XCTAssertEqual(objectHashes, [contentHash])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: vault.layout.rejected.appending(path: job.id.uuidString.lowercased() + ".json").path
      )
    )
  }

  func testRecoveryRejectsInterruptedJobsAndRemovesPartialFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    let jobID = UUID()
    try await vault.database.startImport(
      id: jobID,
      filename: "interrupted.gpx",
      sourcePath: nil,
      kind: .gpx
    )
    let partial = vault.layout.incoming.appending(path: "unfinished.partial")
    try Data("partial".utf8).write(to: partial)

    let recoveredCount = try await vault.recoverInterruptedImports()
    XCTAssertEqual(recoveredCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    let jobs = try await vault.database.importJobs()
    let job = try XCTUnwrap(jobs.first)
    XCTAssertEqual(job.status, .rejected)
    XCTAssertTrue(job.errorMessage?.contains("interrupted") == true)
  }

  func testIntegrityCheckDetectsMissingAndCorruptObjects() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstSource = root.appending(path: "first.geojson")
    let secondSource = root.appending(path: "second.geojson")
    try geoJSON(name: "First", longitude: -122.4).write(to: firstSource)
    try geoJSON(name: "Second", longitude: -121.4).write(to: secondSource)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    let first = try await vault.importArtifact(at: firstSource)
    let second = try await vault.importArtifact(at: secondSource)

    try FileManager.default.removeItem(at: first.object.url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: second.object.url.path)
    try Data("corrupted".utf8).write(to: second.object.url)
    let report = try await vault.integrityCheck()

    XCTAssertEqual(report.checkedObjects, 2)
    XCTAssertEqual(report.missingObjects, [first.object.sha256])
    XCTAssertEqual(report.corruptedObjects, [second.object.sha256])
    XCTAssertEqual(report.databaseIntegrityMessages, ["ok"])
    XCTAssertFalse(report.isHealthy)
  }

  func testCapacityGuardRejectsImpossibleReserve() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "route.geojson")
    try geoJSON(name: "Walk", longitude: -122).write(to: source)
    let vault = try ActivityVault(
      rootURL: root.appending(path: "vault"),
      minimumFreeBytes: UInt64.max
    )

    do {
      _ = try await vault.importArtifact(at: source)
      XCTFail("Expected capacity guard to reject the import")
    } catch let error as ActivityVaultError {
      guard case .insufficientSpace = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let jobs = try await vault.database.importJobs()
    let objectHashes = try await vault.database.objectHashes()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertTrue(objectHashes.isEmpty)
  }

  func testNewerCatalogSchemaIsRejected() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = ActivityVaultLayout(root: root.appending(path: "vault"))
    try layout.create()
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(layout.database.path, &database), SQLITE_OK)
    let futureVersion = ActivityVaultSchema.currentVersion + 1
    XCTAssertEqual(
      sqlite3_exec(database, "PRAGMA user_version = \(futureVersion)", nil, nil, nil), SQLITE_OK)
    sqlite3_close_v2(database)

    XCTAssertThrowsError(try ActivityVaultDatabase(layout: layout)) { error in
      guard case ActivityVaultError.database(let message) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("newer than supported"))
    }
  }

  private func makePackage(
    at destination: URL,
    distance: Double,
    payload: Data
  ) throws -> ActivityPackageManifest {
    let start = Date(timeIntervalSince1970: 1_785_330_000)
    let packageID = try XCTUnwrap(
      UUID(uuidString: "B913E9E3-95A6-475E-94A6-D72CF81DE79B")
    )
    let draft = ActivityPackageDraft(
      packageID: packageID,
      packageRevision: 1,
      generatedAt: Date(timeIntervalSince1970: 1_785_331_800.123),
      generator: ActivityPackageGenerator(name: "Activity Manager", version: "1.0"),
      source: ActivitySourceIdentity(
        sourceActivityID: "healthkit:123",
        originalIdentifier: "123",
        sourceBundleIdentifier: "com.apple.health",
        sourceName: "Apple Health"
      ),
      workoutTypeIdentifier: 37,
      workoutTypeName: "Hiking",
      title: "Enchantments",
      startDate: start,
      endDate: start.addingTimeInterval(3_600),
      timeZoneIdentifier: "America/Los_Angeles",
      durationSeconds: 3_600,
      completeness: .final,
      routeState: .unavailable,
      metricsState: .included,
      sourceReportedStatistics: [
        ActivityPackageStatistic(
          identifier: "distance",
          aggregation: "sum",
          value: distance,
          unit: "mi",
          provenance: "HKWorkout.statistics"
        ),
        ActivityPackageStatistic(
          identifier: "elevationGain",
          aggregation: "sum",
          value: 9_415.75,
          unit: "ft",
          provenance: "HKWorkout.statistics"
        ),
      ],
      knownOmissions: ["GPS route unavailable from source."],
      privacyClassifications: [.health]
    )
    return try ActivityPackageWriter.write(
      draft: draft,
      payloads: [
        ActivityPackagePayload(
          path: "source/vendor-original.bin",
          role: .originalArtifact,
          mediaType: "application/octet-stream",
          authority: .original,
          data: payload
        )
      ],
      to: destination
    )
  }

  private func geoJSON(name: String, longitude: Double) -> Data {
    Data(
      """
      {"type":"Feature","properties":{"name":"\(name)"},"geometry":{"type":"LineString","coordinates":[[\(longitude),47.0],[\(longitude + 0.1),47.1]]}}
      """.utf8
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "ActivityArchiveVaultTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
