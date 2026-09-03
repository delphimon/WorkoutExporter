import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import ActivityArchiveCore

final class ActivityPackageTests: XCTestCase {
  func testRoundTripPreservesSourceValuesUnitsAndPayloadBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = root.appending(path: "sample.activitypkg")
    let route = Data("<gpx>source evidence</gpx>".utf8)
    let samples = Data("timestamp,heart_rate\r\n2026-07-29T12:00:00.000Z,103\r\n".utf8)

    let manifest = try ActivityPackageWriter.write(
      draft: makeEvidenceDraft(),
      payloads: [
        ActivityPackagePayload(
          path: "source/route.gpx",
          role: .authoritativeRoute,
          mediaType: "application/gpx+xml",
          authority: .authoritative,
          data: route
        ),
        ActivityPackagePayload(
          path: "metrics/heart-rate.csv",
          role: .metricSeries,
          mediaType: "text/csv",
          authority: .authoritative,
          data: samples
        ),
      ],
      to: packageURL
    )

    XCTAssertEqual(packageURL.pathExtension, ActivityPackageSchema.pathExtension)
    XCTAssertEqual(manifest.sourceReportedStatistics.first?.value, 13.987_654_321)
    XCTAssertEqual(manifest.sourceReportedStatistics.first?.unit, "mi")
    let validated = try ActivityPackageReader().validatePackage(at: packageURL)
    XCTAssertEqual(validated.packageID, manifest.packageID)
    XCTAssertEqual(validated.contentHash, manifest.contentHash)
    XCTAssertEqual(validated.files, manifest.files)
    XCTAssertEqual(validated.events, manifest.events)
    XCTAssertEqual(validated.metricSeries, manifest.metricSeries)
    XCTAssertEqual(validated.routes, manifest.routes)
    XCTAssertEqual(validated.provenance, manifest.provenance)
    XCTAssertEqual(validated.userAnnotations, manifest.userAnnotations)
    XCTAssertEqual(
      validated.generatedAt.timeIntervalSince1970,
      manifest.generatedAt.timeIntervalSince1970,
      accuracy: 0.001)
    let manifestJSON = try rawEntry(named: "manifest.json", in: packageURL)
    let manifestText = try XCTUnwrap(String(data: manifestJSON, encoding: .utf8))
    XCTAssertTrue(manifestText.contains("\"generatedAt\" : \"2026-07-29T13:30:00."))
    XCTAssertEqual(
      try ActivityPackageReader().data(for: "source/route.gpx", inPackageAt: packageURL),
      route
    )
    XCTAssertEqual(
      try ActivityPackageReader().data(
        for: "metrics/heart-rate.csv",
        inPackageAt: packageURL
      ),
      samples
    )
  }

  func testContentHashIsStableAcrossPayloadOrdering() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let payloads = [
      ActivityPackagePayload(
        path: "b.txt",
        role: .attachment,
        mediaType: "text/plain",
        authority: .supplemental,
        data: Data("b".utf8)
      ),
      ActivityPackagePayload(
        path: "a.txt",
        role: .attachment,
        mediaType: "text/plain",
        authority: .supplemental,
        data: Data("a".utf8)
      ),
    ]

    let first = try ActivityPackageWriter.write(
      draft: makeDraft(),
      payloads: payloads,
      to: root.appending(path: "first.activitypkg")
    )
    let second = try ActivityPackageWriter.write(
      draft: makeDraft(),
      payloads: payloads.reversed(),
      to: root.appending(path: "second.activitypkg")
    )

    XCTAssertEqual(first.files, second.files)
    XCTAssertEqual(first.contentHash, second.contentHash)
  }

  func testContentHashChangesWhenSourceEvidenceMetadataChanges() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let payloads = [payload(path: "source.txt", data: "same bytes")]
    let first = try ActivityPackageWriter.write(
      draft: makeDraft(),
      payloads: payloads,
      to: root.appending(path: "first.activitypkg")
    )
    var changed = makeDraft()
    changed.sourceReportedStatistics[0].value = 13.5
    let second = try ActivityPackageWriter.write(
      draft: changed,
      payloads: payloads,
      to: root.appending(path: "second.activitypkg")
    )

    XCTAssertNotEqual(first.contentHash, second.contentHash)
  }

  func testPhysicalValueKeepsSourceAndNormalizedValuesSeparate() throws {
    let value = ActivityPhysicalValue(
      sourceValue: 9_415.75,
      sourceUnit: "ft",
      normalizedValue: 2_870.7214,
      normalizedUnit: "m",
      normalizationMethod: "unit conversion",
      normalizationVersion: "1"
    )
    let encoded = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(ActivityPhysicalValue.self, from: encoded)

    XCTAssertEqual(decoded.sourceValue, 9_415.75)
    XCTAssertEqual(decoded.sourceUnit, "ft")
    XCTAssertEqual(decoded.normalizedValue, 2_870.7214)
    XCTAssertEqual(decoded.normalizedUnit, "m")
  }

  func testPackageIdentityIsStableForLogicalSource() throws {
    let first = try ActivityPackageIdentity.stablePackageID(for: "healthkit:123")
    let second = try ActivityPackageIdentity.stablePackageID(for: "healthkit:123")
    let different = try ActivityPackageIdentity.stablePackageID(for: "healthkit:124")

    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, different)
    XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "5")
  }

  func testActivityPackageTypeAndExtensionAreExposed() {
    XCTAssertEqual(ActivityPackageSchema.pathExtension, "activitypkg")
    XCTAssertEqual(UTType.activityPackage.identifier, ActivityPackageSchema.name)
  }

  func testFilePayloadStreamsWithoutChangingBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source.bin")
    let sourceData = Data((0..<200_000).map { UInt8($0 % 251) })
    try sourceData.write(to: sourceURL)
    let packageURL = root.appending(path: "file.activitypkg")

    _ = try ActivityPackageWriter.write(
      draft: makeDraft(),
      payloads: [
        ActivityPackagePayload(
          path: "source/source.bin",
          role: .originalArtifact,
          mediaType: "application/octet-stream",
          authority: .original,
          fileURL: sourceURL
        )
      ],
      to: packageURL
    )

    XCTAssertEqual(
      try ActivityPackageReader().data(for: "source/source.bin", inPackageAt: packageURL),
      sourceData
    )
  }

  func testWriterRejectsTraversalAbsoluteAndAmbiguousPaths() throws {
    for path in ["../secret", "/absolute", "C:/absolute", "a//b", "a/./b", "a/../b", "a\\b"] {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(
        try ActivityPackageWriter.write(
          draft: makeDraft(),
          payloads: [payload(path: path, data: "unsafe")],
          to: root.appending(path: "unsafe.activitypkg")
        )
      ) { error in
        guard case .invalidPath = error as? ActivityPackageError else {
          return XCTFail("Expected invalidPath, got \(error)")
        }
      }
    }
  }

  func testWriterRejectsUnicodeAndCaseInsensitivePathCollisions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(
      try ActivityPackageWriter.write(
        draft: makeDraft(),
        payloads: [
          payload(path: "Metrics/Heart.csv", data: "one"),
          payload(path: "metrics/heart.csv", data: "two"),
        ],
        to: root.appending(path: "duplicate.activitypkg")
      )
    ) { error in
      guard case .duplicatePath = error as? ActivityPackageError else {
        return XCTFail("Expected duplicatePath, got \(error)")
      }
    }
  }

  func testReaderRejectsTamperedPayload() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = root.appending(path: "tampered.activitypkg")
    let marker = Data("UNIQUE-SOURCE-EVIDENCE".utf8)
    _ = try ActivityPackageWriter.write(
      draft: makeDraft(),
      payloads: [
        ActivityPackagePayload(
          path: "source/evidence.txt",
          role: .originalArtifact,
          mediaType: "text/plain",
          authority: .original,
          data: marker
        )
      ],
      to: packageURL
    )
    var archive = try Data(contentsOf: packageURL)
    let range = try XCTUnwrap(archive.range(of: marker))
    archive[range.lowerBound] ^= 0xff
    try archive.write(to: packageURL, options: .atomic)

    XCTAssertThrowsError(try ActivityPackageReader().validatePackage(at: packageURL)) {
      error in
      guard case .checksumMismatch = error as? ActivityPackageError else {
        return XCTFail("Expected checksumMismatch, got \(error)")
      }
    }
  }

  func testReaderRejectsFilesMissingFromManifest() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = root.appending(path: "unlisted.activitypkg")
    let manifest = try manifestData(files: [])
    let manifestDigest = PayloadDigest(data: manifest)
    let extra = Data("unlisted".utf8)
    let extraDigest = PayloadDigest(data: extra)
    try StoredZIPWriter.write(
      payloads: [
        StoredZIPPayload(
          path: "manifest.json",
          source: .data(manifest),
          byteLength: manifestDigest.byteLength,
          crc32: manifestDigest.crc32,
          sha256: manifestDigest.sha256
        ),
        StoredZIPPayload(
          path: "extra.txt",
          source: .data(extra),
          byteLength: extraDigest.byteLength,
          crc32: extraDigest.crc32,
          sha256: extraDigest.sha256
        ),
      ],
      to: packageURL
    )

    XCTAssertThrowsError(try ActivityPackageReader().validatePackage(at: packageURL)) {
      error in
      XCTAssertEqual(error as? ActivityPackageError, .unexpectedFile("extra.txt"))
    }
  }

  func testReaderRejectsUnsupportedSchemaVersion() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let packageURL = root.appending(path: "future.activitypkg")
    let manifest = try manifestData(files: [], schemaVersion: "2.0.0")
    let digest = PayloadDigest(data: manifest)
    try StoredZIPWriter.write(
      payloads: [
        StoredZIPPayload(
          path: "manifest.json",
          source: .data(manifest),
          byteLength: digest.byteLength,
          crc32: digest.crc32,
          sha256: digest.sha256
        )
      ],
      to: packageURL
    )

    XCTAssertThrowsError(try ActivityPackageReader().validatePackage(at: packageURL)) { error in
      XCTAssertEqual(error as? ActivityPackageError, .unsupportedSchema("2.0.0"))
    }
  }

  func testConfiguredSizeAndFileCountLimitsAreEnforced() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let strictLimits = ActivityPackageLimits(
      maximumFileCount: 1,
      maximumManifestBytes: 2_048,
      maximumFileBytes: 3,
      maximumTotalBytes: 4_096
    )

    XCTAssertThrowsError(
      try ActivityPackageWriter.write(
        draft: makeDraft(),
        payloads: [payload(path: "large.txt", data: "four")],
        to: root.appending(path: "large.activitypkg"),
        limits: strictLimits
      )
    ) { error in
      XCTAssertEqual(error as? ActivityPackageError, .invalidArchive("Too many files"))
    }

    let sizeLimits = ActivityPackageLimits(
      maximumFileCount: 2,
      maximumManifestBytes: 2_048,
      maximumFileBytes: 3,
      maximumTotalBytes: 4_096
    )
    XCTAssertThrowsError(
      try ActivityPackageWriter.write(
        draft: makeDraft(),
        payloads: [payload(path: "large.txt", data: "four")],
        to: root.appending(path: "too-large.activitypkg"),
        limits: sizeLimits
      )
    ) { error in
      XCTAssertEqual(error as? ActivityPackageError, .fileTooLarge("large.txt"))
    }
  }

  func testWriterRequiresRegisteredPackageExtension() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try ActivityPackageWriter.write(
        draft: makeDraft(),
        payloads: [],
        to: root.appending(path: "archive.zip")
      )
    )
  }

  func testInvalidDraftIsRejectedBeforePublication() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "invalid.activitypkg")
    var draft = makeDraft()
    draft.sourceReportedStatistics[0].value = .nan

    XCTAssertThrowsError(
      try ActivityPackageWriter.write(draft: draft, payloads: [], to: destination)
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func makeDraft() -> ActivityPackageDraft {
    ActivityPackageDraft(
      packageID: UUID(uuidString: "B913E9E3-95A6-475E-94A6-D72CF81DE79B")!,
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
      startDate: Date(timeIntervalSince1970: 1_785_330_000),
      endDate: Date(timeIntervalSince1970: 1_785_333_600),
      timeZoneIdentifier: "America/Los_Angeles",
      durationSeconds: 3_600,
      completeness: .final,
      routeState: .unavailable,
      metricsState: .unavailable,
      sourceReportedStatistics: [
        ActivityPackageStatistic(
          identifier: "distance",
          aggregation: "sum",
          value: 13.987_654_321,
          unit: "mi",
          provenance: "HKWorkout.statistics"
        )
      ],
      knownOmissions: [],
      privacyClassifications: [.healthAndPreciseLocation]
    )
  }

  private func makeEvidenceDraft() -> ActivityPackageDraft {
    var draft = makeDraft()
    let start = draft.startDate
    draft.routeState = .included
    draft.metricsState = .included
    draft.events = [
      ActivityPackageEvent(
        eventType: "pause",
        startDate: start.addingTimeInterval(1_200),
        endDate: start.addingTimeInterval(1_260),
        source: "HealthKit"
      )
    ]
    draft.metricSeries = [
      ActivityMetricSeriesDescriptor(
        seriesID: "heart-rate-1",
        identifier: "heartRate",
        payloadPath: "metrics/heart-rate.csv",
        sourceUnit: "count/min",
        aggregation: "discrete",
        startDate: start,
        endDate: draft.endDate,
        sampleCount: 1,
        coverageFraction: 0.95,
        source: "HealthKit"
      )
    ]
    draft.routes = [
      ActivityRouteDescriptor(
        trackID: "route-1",
        authoritativePath: "source/route.gpx",
        elevationUnit: "m",
        segmentCount: 1,
        pointCount: 2,
        hasTimestamps: true,
        completeness: .final,
        source: "HealthKit"
      )
    ]
    draft.provenance = [
      ActivityProvenanceRecord(
        recordID: UUID(uuidString: "3DA2F23E-A165-4D75-B548-DDF2D7D11C87")!,
        subjectPath: "source/route.gpx",
        sourceActivityID: draft.source.sourceActivityID,
        parserName: "Activity Manager HealthKit exporter",
        parserVersion: "1",
        recordedAt: draft.generatedAt
      )
    ]
    draft.userAnnotations = [
      ActivityUserAnnotation(
        key: "locationTag",
        value: "Enchantments",
        modifiedAt: draft.generatedAt
      )
    ]
    return draft
  }

  private func payload(path: String, data: String) -> ActivityPackagePayload {
    ActivityPackagePayload(
      path: path,
      role: .attachment,
      mediaType: "text/plain",
      authority: .supplemental,
      data: Data(data.utf8)
    )
  }

  private func manifestData(
    files: [ActivityPackageFileEntry],
    schemaVersion: String = ActivityPackageSchema.currentVersion
  ) throws -> Data {
    let draft = makeDraft()
    let manifest = ActivityPackageManifest(
      schemaVersion: schemaVersion,
      packageID: draft.packageID,
      packageRevision: draft.packageRevision,
      contentHash: try ActivityPackageWriter.contentHash(for: files, draft: draft),
      generatedAt: draft.generatedAt,
      generator: draft.generator,
      source: draft.source,
      workoutTypeIdentifier: draft.workoutTypeIdentifier,
      workoutTypeName: draft.workoutTypeName,
      title: draft.title,
      startDate: draft.startDate,
      endDate: draft.endDate,
      timeZoneIdentifier: draft.timeZoneIdentifier,
      durationSeconds: draft.durationSeconds,
      completeness: draft.completeness,
      routeState: draft.routeState,
      metricsState: draft.metricsState,
      sourceReportedStatistics: draft.sourceReportedStatistics,
      files: files,
      knownOmissions: draft.knownOmissions,
      privacyClassifications: draft.privacyClassifications
    )
    return try ActivityPackageJSON.encoder().encode(manifest)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func rawEntry(named path: String, in packageURL: URL) throws -> Data {
    let archive = try StoredZIPArchive(url: packageURL, limits: ActivityPackageLimits())
    let entry = try XCTUnwrap(archive.entry(named: path))
    return try archive.data(for: entry, maximumBytes: 2 * 1_024 * 1_024)
  }
}
