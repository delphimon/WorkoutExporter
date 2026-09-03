import CryptoKit
import Foundation

public enum ActivityPackageWriter {
  public static func write(
    draft: ActivityPackageDraft,
    payloads: [ActivityPackagePayload],
    to destination: URL,
    limits: ActivityPackageLimits = ActivityPackageLimits()
  ) throws -> ActivityPackageManifest {
    try limits.validate()
    guard destination.pathExtension.lowercased() == ActivityPackageSchema.pathExtension else {
      throw ActivityPackageError.invalidArchive(
        "Destination must use the .\(ActivityPackageSchema.pathExtension) extension"
      )
    }
    try validate(draft: draft)
    guard payloads.count + 1 <= limits.maximumFileCount else {
      throw ActivityPackageError.invalidArchive("Too many files")
    }

    var normalizedPaths = Set<String>()
    var prepared: [StoredZIPPayload] = []
    var entries: [ActivityPackageFileEntry] = []
    var totalBytes: UInt64 = 0

    for payload in payloads {
      let path = try ActivityPackagePath.validated(payload.path)
      let collisionKey = path.lowercased()
      guard collisionKey != "manifest.json" else {
        throw ActivityPackageError.duplicatePath(path)
      }
      guard normalizedPaths.insert(collisionKey).inserted else {
        throw ActivityPackageError.duplicatePath(path)
      }

      let digest = try PayloadDigest(source: payload.source)
      guard digest.byteLength <= limits.maximumFileBytes else {
        throw ActivityPackageError.fileTooLarge(path)
      }
      totalBytes = try adding(digest.byteLength, to: totalBytes, limit: limits.maximumTotalBytes)
      prepared.append(
        StoredZIPPayload(
          path: path,
          source: payload.source,
          byteLength: digest.byteLength,
          crc32: digest.crc32,
          sha256: digest.sha256
        )
      )
      entries.append(
        ActivityPackageFileEntry(
          path: path,
          role: payload.role,
          mediaType: payload.mediaType,
          byteLength: digest.byteLength,
          sha256: digest.sha256,
          authority: payload.authority
        )
      )
    }

    entries.sort { $0.path < $1.path }
    try ActivityEvidenceValidator.validate(
      events: draft.events,
      metricSeries: draft.metricSeries,
      routes: draft.routes,
      provenance: draft.provenance,
      userAnnotations: draft.userAnnotations,
      files: entries
    )
    let contentHash = try contentHash(for: entries, draft: draft)
    let manifest = ActivityPackageManifest(
      packageID: draft.packageID,
      packageRevision: draft.packageRevision,
      contentHash: contentHash,
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
      events: draft.events,
      metricSeries: draft.metricSeries,
      routes: draft.routes,
      provenance: draft.provenance,
      userAnnotations: draft.userAnnotations,
      completeness: draft.completeness,
      routeState: draft.routeState,
      metricsState: draft.metricsState,
      sourceReportedStatistics: draft.sourceReportedStatistics,
      files: entries,
      knownOmissions: draft.knownOmissions,
      privacyClassifications: draft.privacyClassifications
    )
    let manifestData = try ActivityPackageJSON.encoder().encode(manifest)
    guard UInt64(manifestData.count) <= limits.maximumManifestBytes else {
      throw ActivityPackageError.fileTooLarge("manifest.json")
    }
    _ = try adding(
      UInt64(manifestData.count),
      to: totalBytes,
      limit: limits.maximumTotalBytes
    )
    let manifestDigest = PayloadDigest(data: manifestData)
    prepared.append(
      StoredZIPPayload(
        path: "manifest.json",
        source: .data(manifestData),
        byteLength: manifestDigest.byteLength,
        crc32: manifestDigest.crc32,
        sha256: manifestDigest.sha256
      )
    )

    try StoredZIPWriter.write(payloads: prepared, to: destination)
    return manifest
  }

  private static func validate(draft: ActivityPackageDraft) throws {
    guard draft.packageRevision > 0 else {
      throw ActivityPackageError.invalidManifest("Package revision must be at least 1")
    }
    guard !draft.source.sourceActivityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ActivityPackageError.invalidManifest("Source activity ID is required")
    }
    guard !draft.source.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ActivityPackageError.invalidManifest("Source name is required")
    }
    guard !draft.workoutTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ActivityPackageError.invalidManifest("Workout type name is required")
    }
    guard draft.endDate >= draft.startDate,
      draft.durationSeconds.isFinite,
      draft.durationSeconds >= 0
    else {
      throw ActivityPackageError.invalidManifest("Workout dates or duration are invalid")
    }
    guard TimeZone(identifier: draft.timeZoneIdentifier) != nil else {
      throw ActivityPackageError.invalidManifest("A valid time-zone identifier is required")
    }
    guard
      draft.sourceReportedStatistics.allSatisfy({ statistic in
        statistic.value.isFinite
          && !statistic.identifier.isEmpty
          && !statistic.aggregation.isEmpty
          && !statistic.unit.isEmpty
          && !statistic.provenance.isEmpty
      })
    else {
      throw ActivityPackageError.invalidManifest(
        "Statistics require identifiers, units, provenance, and finite values"
      )
    }
  }

  static func contentHash(
    for entries: [ActivityPackageFileEntry],
    draft: ActivityPackageDraft
  ) throws -> String {
    try contentHash(
      ActivityPackageContentFingerprint(
        source: draft.source,
        workoutTypeIdentifier: draft.workoutTypeIdentifier,
        workoutTypeName: draft.workoutTypeName,
        title: draft.title,
        startDate: draft.startDate,
        endDate: draft.endDate,
        timeZoneIdentifier: draft.timeZoneIdentifier,
        durationSeconds: draft.durationSeconds,
        events: draft.events,
        metricSeries: draft.metricSeries,
        routes: draft.routes,
        provenance: draft.provenance,
        userAnnotations: draft.userAnnotations,
        completeness: draft.completeness,
        routeState: draft.routeState,
        metricsState: draft.metricsState,
        sourceReportedStatistics: draft.sourceReportedStatistics,
        files: entries.sorted { $0.path < $1.path },
        knownOmissions: draft.knownOmissions,
        privacyClassifications: draft.privacyClassifications
      )
    )
  }

  static func contentHash(for manifest: ActivityPackageManifest) throws -> String {
    try contentHash(
      ActivityPackageContentFingerprint(
        source: manifest.source,
        workoutTypeIdentifier: manifest.workoutTypeIdentifier,
        workoutTypeName: manifest.workoutTypeName,
        title: manifest.title,
        startDate: manifest.startDate,
        endDate: manifest.endDate,
        timeZoneIdentifier: manifest.timeZoneIdentifier,
        durationSeconds: manifest.durationSeconds,
        events: manifest.events,
        metricSeries: manifest.metricSeries,
        routes: manifest.routes,
        provenance: manifest.provenance,
        userAnnotations: manifest.userAnnotations,
        completeness: manifest.completeness,
        routeState: manifest.routeState,
        metricsState: manifest.metricsState,
        sourceReportedStatistics: manifest.sourceReportedStatistics,
        files: manifest.files.sorted { $0.path < $1.path },
        knownOmissions: manifest.knownOmissions,
        privacyClassifications: manifest.privacyClassifications
      )
    )
  }

  private static func contentHash(_ fingerprint: ActivityPackageContentFingerprint) throws -> String
  {
    ActivityPackageHash.sha256(try ActivityPackageJSON.encoder().encode(fingerprint))
  }

  private static func adding(_ value: UInt64, to total: UInt64, limit: UInt64) throws -> UInt64 {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard !overflow, sum <= limit else { throw ActivityPackageError.archiveTooLarge }
    return sum
  }
}

public struct ActivityPackageReader: Sendable {
  public var limits: ActivityPackageLimits

  public init(limits: ActivityPackageLimits = ActivityPackageLimits()) {
    self.limits = limits
  }

  public func validatePackage(at url: URL) throws -> ActivityPackageManifest {
    try limits.validate()
    let archive = try StoredZIPArchive(url: url, limits: limits)
    guard let manifestEntry = archive.entry(named: "manifest.json") else {
      throw ActivityPackageError.missingFile("manifest.json")
    }
    guard manifestEntry.byteLength <= limits.maximumManifestBytes else {
      throw ActivityPackageError.fileTooLarge("manifest.json")
    }
    let manifestData = try archive.data(
      for: manifestEntry, maximumBytes: limits.maximumManifestBytes)
    let manifest: ActivityPackageManifest
    do {
      manifest = try ActivityPackageJSON.decoder().decode(
        ActivityPackageManifest.self,
        from: manifestData
      )
    } catch {
      throw ActivityPackageError.invalidManifest(error.localizedDescription)
    }
    try validate(manifest: manifest, archive: archive)
    return manifest
  }

  public func data(
    for path: String,
    inPackageAt url: URL,
    maximumBytes: UInt64? = nil
  ) throws -> Data {
    _ = try validatePackage(at: url)
    let archive = try StoredZIPArchive(url: url, limits: limits)
    let path = try ActivityPackagePath.validated(path)
    guard path != "manifest.json", let entry = archive.entry(named: path) else {
      throw ActivityPackageError.missingFile(path)
    }
    return try archive.data(
      for: entry,
      maximumBytes: min(maximumBytes ?? limits.maximumFileBytes, limits.maximumFileBytes)
    )
  }

  private func validate(
    manifest: ActivityPackageManifest,
    archive: StoredZIPArchive
  ) throws {
    guard manifest.schemaName == ActivityPackageSchema.name else {
      throw ActivityPackageError.invalidManifest("Unexpected schema name")
    }
    guard manifest.schemaVersion == ActivityPackageSchema.currentVersion else {
      throw ActivityPackageError.unsupportedSchema(manifest.schemaVersion)
    }
    guard manifest.packageRevision > 0,
      !manifest.source.sourceActivityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !manifest.source.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !manifest.workoutTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      manifest.endDate >= manifest.startDate,
      manifest.durationSeconds.isFinite,
      manifest.durationSeconds >= 0,
      TimeZone(identifier: manifest.timeZoneIdentifier) != nil,
      manifest.sourceReportedStatistics.allSatisfy({ statistic in
        statistic.value.isFinite
          && !statistic.identifier.isEmpty
          && !statistic.aggregation.isEmpty
          && !statistic.unit.isEmpty
          && !statistic.provenance.isEmpty
      })
    else {
      throw ActivityPackageError.invalidManifest("Identity, dates, or duration are invalid")
    }

    var listed = Set<String>()
    for file in manifest.files {
      let path = try ActivityPackagePath.validated(file.path)
      guard path != "manifest.json" else {
        throw ActivityPackageError.invalidManifest(
          "manifest.json cannot list itself as a payload"
        )
      }
      guard !file.mediaType.isEmpty else {
        throw ActivityPackageError.invalidManifest("Media type is required for \(path)")
      }
      let key = path.precomposedStringWithCanonicalMapping.lowercased()
      guard listed.insert(key).inserted else {
        throw ActivityPackageError.duplicatePath(path)
      }
      guard let entry = archive.entry(named: path) else {
        throw ActivityPackageError.missingFile(path)
      }
      guard file.sha256.count == 64,
        file.sha256.unicodeScalars.allSatisfy({
          (48...57).contains($0.value) || (97...102).contains($0.value)
        })
      else {
        throw ActivityPackageError.invalidManifest("Invalid SHA-256 for \(path)")
      }
      guard entry.byteLength == file.byteLength else {
        throw ActivityPackageError.byteLengthMismatch(path)
      }
      let hash = try archive.sha256(for: entry)
      guard hash == file.sha256.lowercased() else {
        throw ActivityPackageError.checksumMismatch(path)
      }
    }
    guard manifest.contentHash.count == 64,
      manifest.contentHash.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      })
    else {
      throw ActivityPackageError.invalidManifest("Invalid content hash")
    }

    try ActivityEvidenceValidator.validate(
      events: manifest.events,
      metricSeries: manifest.metricSeries,
      routes: manifest.routes,
      provenance: manifest.provenance,
      userAnnotations: manifest.userAnnotations,
      files: manifest.files
    )

    for entry in archive.entries where entry.path != "manifest.json" {
      let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
      guard listed.contains(key) else {
        throw ActivityPackageError.unexpectedFile(entry.path)
      }
    }
    guard manifest.contentHash == (try ActivityPackageWriter.contentHash(for: manifest)) else {
      throw ActivityPackageError.checksumMismatch("manifest contentHash")
    }
  }
}

private struct ActivityPackageContentFingerprint: Encodable {
  var source: ActivitySourceIdentity
  var workoutTypeIdentifier: UInt
  var workoutTypeName: String
  var title: String?
  var startDate: Date
  var endDate: Date
  var timeZoneIdentifier: String
  var durationSeconds: Double
  var events: [ActivityPackageEvent]
  var metricSeries: [ActivityMetricSeriesDescriptor]
  var routes: [ActivityRouteDescriptor]
  var provenance: [ActivityProvenanceRecord]
  var userAnnotations: [ActivityUserAnnotation]
  var completeness: ActivityPackageCompleteness
  var routeState: ActivityPackageRouteState
  var metricsState: ActivityPackageMetricsState
  var sourceReportedStatistics: [ActivityPackageStatistic]
  var files: [ActivityPackageFileEntry]
  var knownOmissions: [String]
  var privacyClassifications: [ActivityPackagePrivacyClassification]
}

enum ActivityPackageJSON {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(ActivityPackageDate.string(from: date))
    }
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = ActivityPackageDate.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid ISO 8601 date"
        )
      }
      return date
    }
    return decoder
  }
}

enum ActivityPackageDate {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(from string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}

enum ActivityPackagePath {
  static func validated(_ input: String) throws -> String {
    guard !input.isEmpty,
      input.utf8.count <= 1_024,
      !input.hasPrefix("/"),
      !input.contains(":"),
      !input.contains("\\"),
      !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ActivityPackageError.invalidPath(input)
    }
    let components = input.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw ActivityPackageError.invalidPath(input)
    }
    let normalized = input.precomposedStringWithCanonicalMapping
    guard normalized == input else {
      throw ActivityPackageError.invalidPath(input)
    }
    return normalized
  }
}

struct PayloadDigest {
  var sha256: String
  var byteLength: UInt64
  var crc32: UInt32

  private init(sha256: String, byteLength: UInt64, crc32: UInt32) {
    self.sha256 = sha256
    self.byteLength = byteLength
    self.crc32 = crc32
  }

  init(data: Data) {
    sha256 = ActivityPackageHash.sha256(data)
    byteLength = UInt64(data.count)
    var checksum = ActivityPackageCRC32()
    checksum.update(data)
    crc32 = checksum.finalized
  }

  init(source: ActivityPackagePayloadSource) throws {
    switch source {
    case .data(let data):
      self.init(data: data)
    case .file(let url):
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      var checksum = ActivityPackageCRC32()
      var size: UInt64 = 0
      while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        try Task.checkCancellation()
        let (newSize, overflow) = size.addingReportingOverflow(UInt64(chunk.count))
        guard !overflow else { throw ActivityPackageError.archiveTooLarge }
        size = newSize
        hasher.update(data: chunk)
        checksum.update(chunk)
      }
      self = PayloadDigest(
        sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        byteLength: size,
        crc32: checksum.finalized
      )
    }
  }
}

enum ActivityPackageHash {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct ActivityPackageCRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var entry = UInt32(value)
    for _ in 0..<8 {
      entry = entry & 1 == 1 ? 0xedb8_8320 ^ (entry >> 1) : entry >> 1
    }
    return entry
  }

  private var value: UInt32 = 0xffff_ffff

  mutating func update(_ data: Data) {
    for byte in data {
      value = Self.table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
    }
  }

  var finalized: UInt32 { value ^ 0xffff_ffff }
}
