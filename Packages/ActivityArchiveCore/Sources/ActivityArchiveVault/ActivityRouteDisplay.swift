import ActivityArchiveCore
import CoreFoundation
import Foundation

public struct ActivityDisplayPoint: Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double
  public let sourcePointIndex: UInt64
}

public struct ActivityDisplaySegment: Identifiable, Equatable, Sendable {
  public let id: String
  public let sourceSegmentReference: String
  public var points: [ActivityDisplayPoint]
}

/// Ephemeral, versioned display derivative. Never persisted over source evidence.
public struct ActivityRouteDisplay: Equatable, Sendable {
  public let sourceObjectHash: String
  public let algorithmVersion: String
  public let sourcePointCount: Int
  public let segments: [ActivityDisplaySegment]
  public var displayedPointCount: Int { segments.reduce(0) { $0 + $1.points.count } }
}

extension ActivityVault {
  public func routeDisplay(observationID: Int64) async throws -> ActivityRouteDisplay {
    let detail = try await database.observationDetail(id: observationID)
    let observation = detail.observation
    let url = try await objectStore.objectURL(for: observation.objectHash)
    guard try await objectStore.verify(hash: observation.objectHash) else {
      throw ActivityVaultError.objectHashMismatch(observation.objectHash)
    }
    let work = Task.detached(priority: .userInitiated) {
      try ActivityRouteDisplayReader.read(
        url: url, kind: observation.kind, hash: observation.objectHash)
    }
    return try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
  }
}

enum ActivityRouteDisplayReader {
  static func read(url: URL, kind: ActivityImportKind, hash: String) throws -> ActivityRouteDisplay
  {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey,
    ])
    guard values.isSymbolicLink != true, values.isRegularFile == true,
      (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 * 1024
    else {
      throw ActivityVaultError.invalidArtifact("Route object is not a supported regular file")
    }
    let builder = RouteDisplayBuilder()
    switch kind {
    case .gpx:
      guard let parser = XMLParser(contentsOf: url) else { throw invalidRoute() }
      try parseGPX(parser, builder: builder)
    case .geoJSON:
      guard (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else {
        throw ActivityVaultError.invalidArtifact(
          "GeoJSON preview exceeds 16 MB. The original remains retained.")
      }
      try parseGeoJSON(JSONSerialization.jsonObject(with: Data(contentsOf: url)), builder: builder)
    case .activityPackage:
      let reader = ActivityPackageReader()
      let manifest = try reader.validatePackage(at: url)
      let paths = Set(manifest.routes.map(\.authoritativePath)).sorted()
      guard paths.count <= 64 else { throw invalidRoute() }
      for path in paths {
        try Task.checkCancellation()
        if path.lowercased().hasSuffix(".gpx") {
          let data = try reader.data(for: path, inPackageAt: url, maximumBytes: 16 * 1024 * 1024)
          try parseGPX(XMLParser(data: data), builder: builder)
        } else if path.lowercased().hasSuffix(".geojson") {
          let data = try reader.data(for: path, inPackageAt: url, maximumBytes: 16 * 1024 * 1024)
          try parseGeoJSON(JSONSerialization.jsonObject(with: data), builder: builder)
        } else if path.lowercased().hasSuffix(".jsonl") {
          var pending = Data()
          var previousSegment: String?
          var lineIndex: UInt64 = 0
          func consumeLine(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latitude = number(value["latitude"]), let longitude = number(value["longitude"])
            else { throw invalidRoute() }
            if let routeID = value["routeID"] {
              guard let text = routeID as? String, !text.isEmpty, text.utf8.count <= 1024 else {
                throw invalidRoute()
              }
            }
            if let segmentIndex = value["segmentIndex"] {
              guard let number = number(segmentIndex), number >= 0, number <= Double(Int64.max),
                number.rounded(.down) == number
              else { throw invalidRoute() }
            }
            let segment =
              (value["routeID"] as? String ?? path) + ":"
              + String(describing: value["segmentIndex"] ?? 0)
            if previousSegment != segment {
              try builder.beginSegment(sourceReference: path + ":" + segment)
              previousSegment = segment
              lineIndex = 0
            }
            // Line ordinal identifies the original point without rounding any source sequence.
            try builder.append(latitude: latitude, longitude: longitude, index: lineIndex)
            lineIndex += 1
          }
          try reader.streamPayload(for: path, inPackageAt: url) { chunk in
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
              guard pending.distance(from: pending.startIndex, to: end) <= 256 * 1024 else {
                throw invalidRoute()
              }
              try consumeLine(Data(pending[..<end]))
              pending.removeSubrange(...end)
            }
            guard pending.count <= 256 * 1024 else { throw invalidRoute() }
          }
          if !pending.isEmpty { try consumeLine(pending) }
        } else {
          throw ActivityVaultError.invalidArtifact(
            "The authoritative route format has no preview decoder. The original remains retained.")
        }
      }
    }
    try Task.checkCancellation()
    return ActivityRouteDisplay(
      sourceObjectHash: hash, algorithmVersion: "source-stride-preview/1",
      sourcePointCount: builder.count, segments: builder.finish())
  }

  private static func parseGPX(_ parser: XMLParser, builder: RouteDisplayBuilder) throws {
    let delegate = RouteDisplayXMLParser(builder: builder)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    let success = parser.parse()
    if let error = delegate.error { throw error }
    guard success else { throw invalidRoute() }
  }

  private static func parseGeoJSON(_ value: Any, builder: RouteDisplayBuilder, depth: Int = 0)
    throws
  {
    try Task.checkCancellation()
    guard depth <= 64, let object = value as? [String: Any] else { throw invalidRoute() }
    switch object["type"] as? String {
    case "FeatureCollection":
      guard let children = object["features"] as? [Any] else { throw invalidRoute() }
      for child in children { try parseGeoJSON(child, builder: builder, depth: depth + 1) }
    case "GeometryCollection":
      guard let children = object["geometries"] as? [Any] else { throw invalidRoute() }
      for child in children { try parseGeoJSON(child, builder: builder, depth: depth + 1) }
    case "Feature":
      guard let geometry = object["geometry"] else { throw invalidRoute() }
      try parseGeoJSON(geometry, builder: builder, depth: depth + 1)
    case "LineString": try line(object["coordinates"], builder: builder)
    case "MultiLineString":
      guard let lines = object["coordinates"] as? [Any] else { throw invalidRoute() }
      for coordinates in lines { try line(coordinates, builder: builder) }
    case "Point", "MultiPoint", "Polygon", "MultiPolygon": break
    default: throw invalidRoute()
    }
  }

  private static func line(_ value: Any?, builder: RouteDisplayBuilder) throws {
    guard let points = value as? [[Any]] else { throw invalidRoute() }
    try builder.beginSegment()
    for (index, point) in points.enumerated() {
      guard point.count >= 2, let longitude = number(point[0]), let latitude = number(point[1])
      else { throw invalidRoute() }
      try builder.append(latitude: latitude, longitude: longitude, index: UInt64(index))
    }
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.doubleValue
  }

  private static func invalidRoute() -> ActivityVaultError {
    .invalidArtifact(
      "Route preview is malformed or exceeds its safety limits. Original evidence remains retained."
    )
  }
}

private final class RouteDisplayBuilder {
  var count = 0
  private var segments: [ActivityDisplaySegment] = []
  private var stride: UInt64 = 1
  private var storedCount = 0
  private var last: ActivityDisplayPoint?

  func beginSegment(sourceReference: String? = nil) throws {
    finishSegment()
    guard segments.count < 512 else {
      throw ActivityVaultError.invalidArtifact("Preview exceeds 512 segments")
    }
    segments.append(
      ActivityDisplaySegment(
        id: "segment-\(segments.count)",
        sourceSegmentReference: sourceReference ?? "original-segment-ordinal:\(segments.count)",
        points: []))
  }

  func append(latitude: Double, longitude: Double, index: UInt64) throws {
    try Task.checkCancellation()
    guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
      (-180...180).contains(longitude), count < 10_000_000
    else {
      throw ActivityVaultError.invalidArtifact(
        "Route preview has an invalid coordinate or exceeds 10 million points")
    }
    if segments.isEmpty { try beginSegment() }
    let point = ActivityDisplayPoint(
      latitude: latitude, longitude: longitude, sourcePointIndex: index)
    count += 1
    if index.isMultiple(of: stride) || segments[segments.count - 1].points.isEmpty {
      segments[segments.count - 1].points.append(point)
      storedCount += 1
    }
    last = point
    if storedCount > 12_000 {
      stride *= 2
      for index in segments.indices {
        let points = segments[index].points
        segments[index].points = points.enumerated().compactMap { offset, point in
          offset == 0 || offset == points.count - 1 || point.sourcePointIndex.isMultiple(of: stride)
            ? point : nil
        }
      }
      storedCount = segments.reduce(0) { $0 + $1.points.count }
    }
  }

  func finish() -> [ActivityDisplaySegment] {
    finishSegment()
    return segments.filter { !$0.points.isEmpty }
  }

  private func finishSegment() {
    if let last, !segments.isEmpty, segments[segments.count - 1].points.last != last {
      segments[segments.count - 1].points.append(last)
      storedCount += 1
    }
    last = nil
  }
}

private final class RouteDisplayXMLParser: NSObject, XMLParserDelegate {
  let builder: RouteDisplayBuilder
  var error: Error?
  private var depth = 0
  private var pointIndex: UInt64 = 0
  init(builder: RouteDisplayBuilder) { self.builder = builder }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    do {
      try Task.checkCancellation()
      depth += 1
      guard depth <= 64 else {
        throw ActivityVaultError.invalidArtifact("Route XML exceeds 64 levels")
      }
      let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
      if ["trk", "trkseg", "rte"].contains(name) {
        try builder.beginSegment()
        pointIndex = 0
      }
      if ["trkpt", "rtept"].contains(name) {
        guard let latitude = attributes["lat"].flatMap(Double.init),
          let longitude = attributes["lon"].flatMap(Double.init)
        else {
          throw ActivityVaultError.invalidArtifact("Route preview contains an invalid point")
        }
        try builder.append(latitude: latitude, longitude: longitude, index: pointIndex)
        pointIndex += 1
      }
    } catch {
      self.error = error
      parser.abortParsing()
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) { depth -= 1 }
  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) {
    error = ActivityVaultError.invalidArtifact("Route preview does not expand XML entities")
    parser.abortParsing()
  }
  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) {
    error = ActivityVaultError.invalidArtifact("Route preview does not resolve XML entities")
    parser.abortParsing()
  }
}
