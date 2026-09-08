import ActivityArchiveCore
import Foundation
import XCTest

@testable import ActivityArchiveVault

final class ActivityRouteDisplayTests: XCTestCase, @unchecked Sendable {
  func testHundredThousandPointPreviewIsBoundedKeepsEndpointsAndOriginalBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "long.gpx")
    var xml = "<gpx><trk><trkseg>"
    for index in 0..<100_000 {
      xml += "<trkpt lat=\"\(47 + Double(index) / 1_000_000)\" lon=\"-122.123456789\"/>"
    }
    xml +=
      "</trkseg><trkseg><trkpt lat=\"48.123456789\" lon=\"-121.987654321\"/></trkseg></trk></gpx>"
    let original = Data(xml.utf8)
    try original.write(to: file)
    let start = ContinuousClock.now
    let route = try ActivityRouteDisplayReader.read(url: file, kind: .gpx, hash: "fixture-hash")
    let duration = start.duration(to: .now)
    print(
      "ROUTE BENCHMARK 100001-point GPX display decode: \(duration), retained \(route.displayedPointCount) points"
    )
    XCTAssertLessThan(duration, .seconds(2))
    XCTAssertEqual(route.sourcePointCount, 100_001)
    XCTAssertLessThanOrEqual(route.displayedPointCount, 12_512)
    XCTAssertEqual(route.segments.count, 2)
    XCTAssertEqual(route.segments[0].points.first?.sourcePointIndex, 0)
    XCTAssertEqual(route.segments[0].points.last?.sourcePointIndex, 99_999)
    XCTAssertEqual(route.segments[1].points.first?.latitude, 48.123_456_789)
    XCTAssertEqual(route.segments[1].points.first?.longitude, -121.987_654_321)
    for segment in route.segments {
      let indices = segment.points.map(\.sourcePointIndex)
      XCTAssertEqual(indices, indices.sorted())
      XCTAssertEqual(indices.count, Set(indices).count)
    }
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertEqual(route.algorithmVersion, "source-stride-preview/1")
  }

  func testGeoJSONSegmentsStaySeparateAndBooleanCoordinatesAreRejected() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "route.geojson")
    let bytes = Data(
      "{\"type\":\"MultiLineString\",\"coordinates\":[[[-122,47],[-121,48]],[[-120,49],[-119,50]]]}"
        .utf8)
    try bytes.write(to: file)
    let route = try ActivityRouteDisplayReader.read(url: file, kind: .geoJSON, hash: "fixture")
    XCTAssertEqual(route.segments.count, 2)
    XCTAssertEqual(route.sourcePointCount, 4)
    try Data("{\"type\":\"LineString\",\"coordinates\":[[true,47],[-122,48]]}".utf8).write(to: file)
    XCTAssertThrowsError(
      try ActivityRouteDisplayReader.read(url: file, kind: .geoJSON, hash: "fixture"))
  }

  func testPackageAuthoritativeJSONLStreamsAndKeepsTrackBoundaries() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "source.activitypkg")
    let payloadPath = "source/points.jsonl"
    let source = ActivitySourceIdentity(
      sourceActivityID: "fixture:1", originalIdentifier: "original", sourceName: "Fixture Watch",
      deviceName: "Watch", deviceModel: "Fixture model")
    let date = Date(timeIntervalSince1970: 1000)
    var draft = ActivityPackageDraft(
      packageID: UUID(), packageRevision: 1, generatedAt: date,
      generator: ActivityPackageGenerator(name: "Fixture", version: "1"), source: source,
      workoutTypeIdentifier: 37, workoutTypeName: "Hiking", title: "Separate title",
      startDate: date,
      endDate: date.addingTimeInterval(60), timeZoneIdentifier: "UTC", durationSeconds: 60,
      routes: [
        ActivityRouteDescriptor(
          trackID: "a", authoritativePath: payloadPath, segmentCount: 2,
          pointCount: 3, hasTimestamps: false, completeness: .final, source: "Fixture")
      ],
      completeness: .final, routeState: .included, metricsState: .unavailable,
      sourceReportedStatistics: [
        ActivityPackageStatistic(
          identifier: "ascent", aggregation: "sum", value: 9415.123456789, unit: "ft",
          provenance: "source fixture")
      ])
    let payload = Data(
      """
      {"routeID":"a","sequence":0,"latitude":47.123456789,"longitude":-122.123456789}
      {"routeID":"a","sequence":1,"latitude":47.234567891,"longitude":-122.234567891}
      {"routeID":"b","sequence":0,"latitude":48.345678912,"longitude":-121.345678912}

      """.utf8)
    _ = try ActivityPackageWriter.write(
      draft: draft,
      payloads: [
        ActivityPackagePayload(
          path: payloadPath,
          role: .authoritativeRoute, mediaType: "application/x-ndjson", authority: .authoritative,
          data: payload)
      ], to: file)
    let vault = try ActivityVault(rootURL: root.appending(path: "vault"), minimumFreeBytes: 0)
    let imported = try await vault.importArtifact(at: file)
    let id = try XCTUnwrap(imported.observationID)
    let detail = try await vault.database.observationDetail(id: id)
    XCTAssertEqual(detail.deviceName, "Watch")
    XCTAssertEqual(detail.statistics.first?.value, 9415.123456789)
    XCTAssertEqual(detail.statistics.first?.unit, "ft")
    // A repeated logical revision may have different container bytes (generation metadata).
    // Its import job must still link to the retained source observation.
    draft.generatedAt = date.addingTimeInterval(10)
    let repeatedFile = root.appending(path: "redelivered.activitypkg")
    _ = try ActivityPackageWriter.write(
      draft: draft,
      payloads: [
        ActivityPackagePayload(
          path: payloadPath,
          role: .authoritativeRoute, mediaType: "application/x-ndjson", authority: .authoritative,
          data: payload)
      ], to: repeatedFile)
    let repeated = try await vault.importArtifact(at: repeatedFile)
    XCTAssertEqual(repeated.status, .duplicate)
    XCTAssertNotEqual(repeated.object.sha256, imported.object.sha256)
    var filter = ActivityCatalogFilter()
    filter.importStatus = .duplicate
    let duplicates = try await vault.database.catalogPage(filter: filter)
    XCTAssertEqual(duplicates.observations.map(\.id), [id])
    let route = try await vault.routeDisplay(observationID: id)
    XCTAssertEqual(route.segments.count, 2)
    XCTAssertEqual(route.sourcePointCount, 3)
    XCTAssertEqual(route.segments[0].points[0].latitude, 47.123456789)
    XCTAssertEqual(route.sourceObjectHash, imported.object.sha256)
    var streamed = Data()
    try ActivityPackageReader().streamPayload(for: payloadPath, inPackageAt: file) {
      streamed.append($0)
    }
    XCTAssertEqual(streamed, payload)
    XCTAssertThrowsError(
      try ActivityPackageReader().streamPayload(for: "../escape", inPackageAt: file) { _ in })
  }

  func testPreviewRejectsEntitiesInvalidPointsDepthAndSegmentBombs() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "hostile.gpx")
    for xml in [
      "<!DOCTYPE gpx [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><gpx><trk><trkseg><trkpt lat=\"&x;\" lon=\"-122\"/></trkseg></trk></gpx>",
      "<gpx><trk><trkseg><trkpt lat=\"999\" lon=\"-122\"/></trkseg></trk></gpx>",
      String(repeating: "<gpx>", count: 65) + String(repeating: "</gpx>", count: 65),
      "<gpx><trk>" + String(repeating: "<trkseg/>", count: 513) + "</trk></gpx>",
    ] {
      try Data(xml.utf8).write(to: file)
      XCTAssertThrowsError(
        try ActivityRouteDisplayReader.read(url: file, kind: .gpx, hash: "fixture"))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "ActivityRouteDisplayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
