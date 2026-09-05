import ActivityArchiveCore
import CoreFoundation
import Foundation

enum ActivityArtifactParser {
  static func kind(for url: URL) throws -> ActivityImportKind {
    switch url.pathExtension.lowercased() {
    case ActivityPackageSchema.pathExtension: .activityPackage
    case "gpx": .gpx
    case "geojson", "json": .geoJSON
    default: throw ActivityVaultError.unsupportedArtifact(url.lastPathComponent)
    }
  }

  static func parse(
    kind: ActivityImportKind,
    object: ActivityStoredObject,
    originalFilename: String
  ) throws -> ImportedObservationDraft {
    switch kind {
    case .activityPackage:
      return try parseActivityPackage(object: object)
    case .gpx:
      return try parseGPX(object: object, originalFilename: originalFilename)
    case .geoJSON:
      return try parseGeoJSON(object: object, originalFilename: originalFilename)
    }
  }

  private static func parseActivityPackage(
    object: ActivityStoredObject
  ) throws -> ImportedObservationDraft {
    let reader = ActivityPackageReader()
    let manifest: ActivityPackageManifest
    do {
      manifest = try reader.validatePackage(at: object.url)
    } catch {
      throw ActivityVaultError.invalidArtifact(error.localizedDescription)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let metadata: Data
    do {
      metadata = try encoder.encode(manifest)
    } catch {
      throw ActivityVaultError.invalidArtifact("Could not index the package manifest")
    }
    return ImportedObservationDraft(
      packageID: manifest.packageID,
      packageRevision: manifest.packageRevision,
      sourceActivityID: manifest.source.sourceActivityID,
      contentHash: manifest.contentHash,
      kind: .activityPackage,
      workoutTypeIdentifier: manifest.workoutTypeIdentifier,
      workoutTypeName: manifest.workoutTypeName,
      title: manifest.title,
      startDate: manifest.startDate,
      endDate: manifest.endDate,
      timeZoneIdentifier: manifest.timeZoneIdentifier,
      durationSeconds: manifest.durationSeconds,
      sourceName: manifest.source.sourceName,
      sourceBundleIdentifier: manifest.source.sourceBundleIdentifier,
      completeness: manifest.completeness.rawValue,
      routeState: manifest.routeState.rawValue,
      metricsState: manifest.metricsState.rawValue,
      sourceStatistics: manifest.sourceReportedStatistics,
      routes: manifest.routes.map {
        ImportedRouteSummary(
          trackID: $0.trackID,
          pointCount: $0.pointCount,
          minimumLatitude: nil,
          maximumLatitude: nil,
          minimumLongitude: nil,
          maximumLongitude: nil,
          hasTimestamps: $0.hasTimestamps
        )
      },
      metadataJSON: metadata,
      warnings: manifest.knownOmissions
    )
  }

  private static func parseGPX(
    object: ActivityStoredObject,
    originalFilename: String
  ) throws -> ImportedObservationDraft {
    let delegate = GPXSummaryParser()
    guard let parser = XMLParser(contentsOf: object.url) else {
      throw ActivityVaultError.invalidArtifact("GPX could not be opened")
    }
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    let didParse = parser.parse()
    if let error = delegate.error { throw error }
    guard didParse, delegate.coordinates.pointCount > 0 else {
      throw ActivityVaultError.invalidArtifact(
        "GPX contains no valid track points"
      )
    }
    let sourceID = "gpx:sha256:\(object.sha256)"
    let title = delegate.name.flatMap { $0.isEmpty ? nil : $0 } ?? "GPX Activity"
    let metadata = try JSONSerialization.data(
      withJSONObject: [
        "originalFilename": originalFilename,
        "format": "GPX",
        "trackName": delegate.name ?? "",
      ],
      options: [.sortedKeys]
    )
    return ImportedObservationDraft(
      packageID: try ActivityPackageIdentity.stablePackageID(for: sourceID),
      packageRevision: 1,
      sourceActivityID: sourceID,
      contentHash: object.sha256,
      kind: .gpx,
      workoutTypeIdentifier: nil,
      workoutTypeName: "Imported Route",
      title: title,
      startDate: delegate.firstDate,
      endDate: delegate.lastDate,
      timeZoneIdentifier: nil,
      durationSeconds: duration(from: delegate.firstDate, to: delegate.lastDate),
      sourceName: "GPX Import",
      sourceBundleIdentifier: nil,
      completeness: "final",
      routeState: "included",
      metricsState: "unavailable",
      sourceStatistics: [],
      routes: [
        delegate.coordinates.summary(trackID: "gpx-track", hasTimestamps: delegate.hasDates)
      ],
      metadataJSON: metadata,
      warnings: delegate.hasDates ? [] : ["GPX route has no usable timestamps."]
    )
  }

  private static func parseGeoJSON(
    object: ActivityStoredObject,
    originalFilename: String
  ) throws -> ImportedObservationDraft {
    guard object.byteLength <= 128 * 1024 * 1024 else {
      throw ActivityVaultError.invalidArtifact(
        "GeoJSON exceeds the 128 MB bounded parser limit"
      )
    }
    let data = try Data(contentsOf: object.url, options: [.mappedIfSafe])
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ActivityVaultError.invalidArtifact("GeoJSON is not valid JSON")
    }
    guard let root = value as? [String: Any] else {
      throw ActivityVaultError.invalidArtifact("GeoJSON root must be an object")
    }
    var accumulator = CoordinateAccumulator()
    try collectGeoJSONCoordinates(root, depth: 0, into: &accumulator)
    guard accumulator.pointCount > 0 else {
      throw ActivityVaultError.invalidArtifact("GeoJSON contains no line coordinates")
    }
    let sourceID = "geojson:sha256:\(object.sha256)"
    let title = geoJSONTitle(root, depth: 0) ?? "GeoJSON Activity"
    let metadata = try JSONSerialization.data(
      withJSONObject: [
        "originalFilename": originalFilename,
        "format": "GeoJSON",
        "rootType": root["type"] as? String ?? "unknown",
        "title": title,
      ],
      options: [.sortedKeys]
    )
    return ImportedObservationDraft(
      packageID: try ActivityPackageIdentity.stablePackageID(for: sourceID),
      packageRevision: 1,
      sourceActivityID: sourceID,
      contentHash: object.sha256,
      kind: .geoJSON,
      workoutTypeIdentifier: nil,
      workoutTypeName: "Imported Route",
      title: title,
      startDate: nil,
      endDate: nil,
      timeZoneIdentifier: nil,
      durationSeconds: nil,
      sourceName: "GeoJSON Import",
      sourceBundleIdentifier: nil,
      completeness: "final",
      routeState: "included",
      metricsState: "unavailable",
      sourceStatistics: [],
      routes: [accumulator.summary(trackID: "geojson-track", hasTimestamps: false)],
      metadataJSON: metadata,
      warnings: ["GeoJSON route has no standardized activity timestamps."]
    )
  }

  private static func collectGeoJSONCoordinates(
    _ object: [String: Any],
    depth: Int,
    into accumulator: inout CoordinateAccumulator
  ) throws {
    try Task.checkCancellation()
    guard depth <= 64 else {
      throw ActivityVaultError.invalidArtifact("GeoJSON geometry nesting exceeds 64 levels")
    }
    switch object["type"] as? String {
    case "FeatureCollection":
      for feature in object["features"] as? [[String: Any]] ?? [] {
        try collectGeoJSONCoordinates(feature, depth: depth + 1, into: &accumulator)
      }
    case "Feature":
      if let geometry = object["geometry"] as? [String: Any] {
        try collectGeoJSONCoordinates(geometry, depth: depth + 1, into: &accumulator)
      }
    case "GeometryCollection":
      for geometry in object["geometries"] as? [[String: Any]] ?? [] {
        try collectGeoJSONCoordinates(geometry, depth: depth + 1, into: &accumulator)
      }
    case "LineString":
      try appendLine(object["coordinates"], into: &accumulator)
    case "MultiLineString":
      guard let lines = object["coordinates"] as? [Any] else { return }
      for line in lines { try appendLine(line, into: &accumulator) }
    default:
      return
    }
  }

  private static func appendLine(
    _ value: Any?,
    into accumulator: inout CoordinateAccumulator
  ) throws {
    guard let coordinates = value as? [Any] else { return }
    for coordinate in coordinates {
      try Task.checkCancellation()
      guard let values = coordinate as? [Any], values.count >= 2,
        let longitude = number(values[0]), let latitude = number(values[1])
      else { continue }
      try accumulator.append(latitude: latitude, longitude: longitude)
    }
  }

  private static func number(_ value: Any) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
  }

  private static func geoJSONTitle(_ root: [String: Any], depth: Int) -> String? {
    guard depth <= 64 else { return nil }
    if let name = root["name"] as? String, !name.isEmpty { return name }
    if let properties = root["properties"] as? [String: Any] {
      for key in ["name", "title"] {
        if let name = properties[key] as? String, !name.isEmpty { return name }
      }
    }
    if let features = root["features"] as? [[String: Any]] {
      return features.lazy.compactMap { geoJSONTitle($0, depth: depth + 1) }.first
    }
    return nil
  }

  private static func duration(from start: Date?, to end: Date?) -> TimeInterval? {
    guard let start, let end else { return nil }
    return max(0, end.timeIntervalSince(start))
  }
}

private final class GPXSummaryParser: NSObject, XMLParserDelegate {
  var coordinates = CoordinateAccumulator()
  var name: String?
  var firstDate: Date?
  var lastDate: Date?
  var error: Error?
  var hasDates = false

  private var text = ""
  private var isInsideTrack = false
  private var isInsidePoint = false

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    if Task.isCancelled {
      error = CancellationError()
      parser.abortParsing()
      return
    }
    let currentElement = normalizedElementName(elementName)
    text = ""
    if currentElement == "trk" { isInsideTrack = true }
    if ["trkpt", "rtept"].contains(currentElement) { isInsidePoint = true }
    guard ["trkpt", "rtept"].contains(currentElement),
      let latitude = attributeDict["lat"].flatMap(Double.init),
      let longitude = attributeDict["lon"].flatMap(Double.init)
    else { return }
    do {
      try coordinates.append(latitude: latitude, longitude: longitude)
    } catch {
      self.error = error
      parser.abortParsing()
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let element = normalizedElementName(elementName)
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if element == "name", isInsideTrack, name == nil, !value.isEmpty {
      name = value
    } else if element == "time", isInsidePoint, let date = Self.date(value) {
      hasDates = true
      firstDate = min(firstDate ?? date, date)
      lastDate = max(lastDate ?? date, date)
    } else if element == "trk" {
      isInsideTrack = false
    }
    if ["trkpt", "rtept"].contains(element) { isInsidePoint = false }
    text = ""
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    if error == nil { error = parseError }
  }

  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private func normalizedElementName(_ value: String) -> String {
    value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
  }
}
