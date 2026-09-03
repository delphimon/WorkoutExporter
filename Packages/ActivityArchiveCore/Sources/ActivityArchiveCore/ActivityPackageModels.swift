import Foundation

public enum ActivityPackageSchema {
  public static let name = "com.delphimon.activity-archive.package"
  public static let currentVersion = "1.0.0"
  public static let mediaType = "application/vnd.activityarchive.package+zip"
  public static let pathExtension = "activitypkg"
}

public enum ActivityPackageCompleteness: String, Codable, Sendable {
  case provisional
  case final
  case tombstone
}

public enum ActivityPackageRouteState: String, Codable, Sendable {
  case pending
  case included
  case unavailable
  case intentionallyExcluded
}

public enum ActivityPackageMetricsState: String, Codable, Sendable {
  case pending
  case included
  case unavailable
  case intentionallyExcluded
}

public enum ActivityPackageFileRole: String, Codable, Sendable {
  case sourceWorkout
  case authoritativeRoute
  case interoperableRoute
  case metricSeries
  case provenance
  case attachment
  case originalArtifact
}

public enum ActivityPackageFileAuthority: String, Codable, Sendable {
  case authoritative
  case supplemental
  case original
}

public enum ActivityPackagePrivacyClassification: String, Codable, Sendable {
  case healthAndPreciseLocation
  case health
  case preciseLocation
  case privateMetadata
}

public struct ActivityPackageGenerator: Codable, Equatable, Sendable {
  public var name: String
  public var version: String

  public init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}

public struct ActivitySourceIdentity: Codable, Equatable, Sendable {
  public var sourceActivityID: String
  public var originalIdentifier: String?
  public var sourceBundleIdentifier: String?
  public var sourceName: String
  public var sourceVersion: String?
  public var deviceName: String?
  public var deviceModel: String?
  public var sourceRevision: String?

  public init(
    sourceActivityID: String,
    originalIdentifier: String? = nil,
    sourceBundleIdentifier: String? = nil,
    sourceName: String,
    sourceVersion: String? = nil,
    deviceName: String? = nil,
    deviceModel: String? = nil,
    sourceRevision: String? = nil
  ) {
    self.sourceActivityID = sourceActivityID
    self.originalIdentifier = originalIdentifier
    self.sourceBundleIdentifier = sourceBundleIdentifier
    self.sourceName = sourceName
    self.sourceVersion = sourceVersion
    self.deviceName = deviceName
    self.deviceModel = deviceModel
    self.sourceRevision = sourceRevision
  }
}

public struct ActivityPackageStatistic: Codable, Equatable, Sendable {
  public var identifier: String
  public var aggregation: String
  public var value: Double
  public var unit: String
  public var provenance: String

  public init(
    identifier: String,
    aggregation: String,
    value: Double,
    unit: String,
    provenance: String
  ) {
    self.identifier = identifier
    self.aggregation = aggregation
    self.value = value
    self.unit = unit
    self.provenance = provenance
  }
}

public struct ActivityPackageFileEntry: Codable, Equatable, Sendable {
  public var path: String
  public var role: ActivityPackageFileRole
  public var mediaType: String
  public var byteLength: UInt64
  public var sha256: String
  public var authority: ActivityPackageFileAuthority

  public init(
    path: String,
    role: ActivityPackageFileRole,
    mediaType: String,
    byteLength: UInt64,
    sha256: String,
    authority: ActivityPackageFileAuthority
  ) {
    self.path = path
    self.role = role
    self.mediaType = mediaType
    self.byteLength = byteLength
    self.sha256 = sha256
    self.authority = authority
  }
}

public struct ActivityPackageManifest: Codable, Equatable, Sendable {
  public var schemaName: String
  public var schemaVersion: String
  public var packageID: UUID
  public var packageRevision: UInt64
  public var contentHash: String
  public var generatedAt: Date
  public var generator: ActivityPackageGenerator
  public var source: ActivitySourceIdentity
  public var workoutTypeIdentifier: UInt
  public var workoutTypeName: String
  public var title: String?
  public var startDate: Date
  public var endDate: Date
  public var timeZoneIdentifier: String
  public var durationSeconds: Double
  public var events: [ActivityPackageEvent]
  public var metricSeries: [ActivityMetricSeriesDescriptor]
  public var routes: [ActivityRouteDescriptor]
  public var provenance: [ActivityProvenanceRecord]
  public var userAnnotations: [ActivityUserAnnotation]
  public var completeness: ActivityPackageCompleteness
  public var routeState: ActivityPackageRouteState
  public var metricsState: ActivityPackageMetricsState
  public var sourceReportedStatistics: [ActivityPackageStatistic]
  public var files: [ActivityPackageFileEntry]
  public var knownOmissions: [String]
  public var privacyClassifications: [ActivityPackagePrivacyClassification]

  public init(
    schemaName: String = ActivityPackageSchema.name,
    schemaVersion: String = ActivityPackageSchema.currentVersion,
    packageID: UUID,
    packageRevision: UInt64,
    contentHash: String,
    generatedAt: Date,
    generator: ActivityPackageGenerator,
    source: ActivitySourceIdentity,
    workoutTypeIdentifier: UInt,
    workoutTypeName: String,
    title: String? = nil,
    startDate: Date,
    endDate: Date,
    timeZoneIdentifier: String,
    durationSeconds: Double,
    events: [ActivityPackageEvent] = [],
    metricSeries: [ActivityMetricSeriesDescriptor] = [],
    routes: [ActivityRouteDescriptor] = [],
    provenance: [ActivityProvenanceRecord] = [],
    userAnnotations: [ActivityUserAnnotation] = [],
    completeness: ActivityPackageCompleteness,
    routeState: ActivityPackageRouteState,
    metricsState: ActivityPackageMetricsState,
    sourceReportedStatistics: [ActivityPackageStatistic],
    files: [ActivityPackageFileEntry],
    knownOmissions: [String],
    privacyClassifications: [ActivityPackagePrivacyClassification]
  ) {
    self.schemaName = schemaName
    self.schemaVersion = schemaVersion
    self.packageID = packageID
    self.packageRevision = packageRevision
    self.contentHash = contentHash
    self.generatedAt = generatedAt
    self.generator = generator
    self.source = source
    self.workoutTypeIdentifier = workoutTypeIdentifier
    self.workoutTypeName = workoutTypeName
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.timeZoneIdentifier = timeZoneIdentifier
    self.durationSeconds = durationSeconds
    self.events = events
    self.metricSeries = metricSeries
    self.routes = routes
    self.provenance = provenance
    self.userAnnotations = userAnnotations
    self.completeness = completeness
    self.routeState = routeState
    self.metricsState = metricsState
    self.sourceReportedStatistics = sourceReportedStatistics
    self.files = files
    self.knownOmissions = knownOmissions
    self.privacyClassifications = privacyClassifications
  }
}

public struct ActivityPackageDraft: Sendable {
  public var packageID: UUID
  public var packageRevision: UInt64
  public var generatedAt: Date
  public var generator: ActivityPackageGenerator
  public var source: ActivitySourceIdentity
  public var workoutTypeIdentifier: UInt
  public var workoutTypeName: String
  public var title: String?
  public var startDate: Date
  public var endDate: Date
  public var timeZoneIdentifier: String
  public var durationSeconds: Double
  public var events: [ActivityPackageEvent]
  public var metricSeries: [ActivityMetricSeriesDescriptor]
  public var routes: [ActivityRouteDescriptor]
  public var provenance: [ActivityProvenanceRecord]
  public var userAnnotations: [ActivityUserAnnotation]
  public var completeness: ActivityPackageCompleteness
  public var routeState: ActivityPackageRouteState
  public var metricsState: ActivityPackageMetricsState
  public var sourceReportedStatistics: [ActivityPackageStatistic]
  public var knownOmissions: [String]
  public var privacyClassifications: [ActivityPackagePrivacyClassification]

  public init(
    packageID: UUID,
    packageRevision: UInt64,
    generatedAt: Date,
    generator: ActivityPackageGenerator,
    source: ActivitySourceIdentity,
    workoutTypeIdentifier: UInt,
    workoutTypeName: String,
    title: String? = nil,
    startDate: Date,
    endDate: Date,
    timeZoneIdentifier: String,
    durationSeconds: Double,
    events: [ActivityPackageEvent] = [],
    metricSeries: [ActivityMetricSeriesDescriptor] = [],
    routes: [ActivityRouteDescriptor] = [],
    provenance: [ActivityProvenanceRecord] = [],
    userAnnotations: [ActivityUserAnnotation] = [],
    completeness: ActivityPackageCompleteness,
    routeState: ActivityPackageRouteState,
    metricsState: ActivityPackageMetricsState,
    sourceReportedStatistics: [ActivityPackageStatistic] = [],
    knownOmissions: [String] = [],
    privacyClassifications: [ActivityPackagePrivacyClassification] = []
  ) {
    self.packageID = packageID
    self.packageRevision = packageRevision
    self.generatedAt = generatedAt
    self.generator = generator
    self.source = source
    self.workoutTypeIdentifier = workoutTypeIdentifier
    self.workoutTypeName = workoutTypeName
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.timeZoneIdentifier = timeZoneIdentifier
    self.durationSeconds = durationSeconds
    self.events = events
    self.metricSeries = metricSeries
    self.routes = routes
    self.provenance = provenance
    self.userAnnotations = userAnnotations
    self.completeness = completeness
    self.routeState = routeState
    self.metricsState = metricsState
    self.sourceReportedStatistics = sourceReportedStatistics
    self.knownOmissions = knownOmissions
    self.privacyClassifications = privacyClassifications
  }
}

public enum ActivityPackagePayloadSource: Sendable {
  case data(Data)
  case file(URL)
}

public struct ActivityPackagePayload: Sendable {
  public var path: String
  public var role: ActivityPackageFileRole
  public var mediaType: String
  public var authority: ActivityPackageFileAuthority
  public var source: ActivityPackagePayloadSource

  public init(
    path: String,
    role: ActivityPackageFileRole,
    mediaType: String,
    authority: ActivityPackageFileAuthority,
    data: Data
  ) {
    self.path = path
    self.role = role
    self.mediaType = mediaType
    self.authority = authority
    self.source = .data(data)
  }

  public init(
    path: String,
    role: ActivityPackageFileRole,
    mediaType: String,
    authority: ActivityPackageFileAuthority,
    fileURL: URL
  ) {
    self.path = path
    self.role = role
    self.mediaType = mediaType
    self.authority = authority
    self.source = .file(fileURL)
  }
}
