import ActivityArchiveCore
import Foundation

struct ImportedObservationDraft: Sendable {
  var packageID: UUID
  var packageRevision: UInt64
  var sourceActivityID: String
  var contentHash: String
  var kind: ActivityImportKind
  var workoutTypeIdentifier: UInt?
  var workoutTypeName: String
  var title: String?
  var startDate: Date?
  var endDate: Date?
  var timeZoneIdentifier: String?
  var durationSeconds: Double?
  var sourceName: String
  var sourceBundleIdentifier: String?
  var completeness: String
  var routeState: String
  var metricsState: String
  var sourceStatistics: [ActivityPackageStatistic]
  var routes: [ImportedRouteSummary]
  var metadataJSON: Data
  var warnings: [String]
}

struct ImportedRouteSummary: Sendable {
  var trackID: String
  var pointCount: UInt64
  var minimumLatitude: Double?
  var maximumLatitude: Double?
  var minimumLongitude: Double?
  var maximumLongitude: Double?
  var hasTimestamps: Bool
}

struct CoordinateAccumulator {
  private static let maximumPointCount: UInt64 = 10_000_000

  private(set) var pointCount: UInt64 = 0
  private(set) var minimumLatitude: Double?
  private(set) var maximumLatitude: Double?
  private(set) var minimumLongitude: Double?
  private(set) var maximumLongitude: Double?

  mutating func append(latitude: Double, longitude: Double) throws {
    guard latitude.isFinite, longitude.isFinite,
      (-90...90).contains(latitude), (-180...180).contains(longitude)
    else {
      throw ActivityVaultError.invalidArtifact("A route coordinate is outside valid bounds")
    }
    guard pointCount < Self.maximumPointCount else {
      throw ActivityVaultError.invalidArtifact("Route exceeds 10 million points")
    }
    pointCount += 1
    minimumLatitude = min(minimumLatitude ?? latitude, latitude)
    maximumLatitude = max(maximumLatitude ?? latitude, latitude)
    minimumLongitude = min(minimumLongitude ?? longitude, longitude)
    maximumLongitude = max(maximumLongitude ?? longitude, longitude)
  }

  func summary(trackID: String, hasTimestamps: Bool) -> ImportedRouteSummary {
    ImportedRouteSummary(
      trackID: trackID,
      pointCount: pointCount,
      minimumLatitude: minimumLatitude,
      maximumLatitude: maximumLatitude,
      minimumLongitude: minimumLongitude,
      maximumLongitude: maximumLongitude,
      hasTimestamps: hasTimestamps
    )
  }
}
