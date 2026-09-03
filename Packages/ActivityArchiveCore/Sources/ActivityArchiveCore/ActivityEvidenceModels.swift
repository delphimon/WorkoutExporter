import Foundation

/// A source value and an optional, explicitly derived SI projection.
///
/// `sourceValue` and `sourceUnit` are immutable evidence. Consumers must never replace them with
/// the normalized fields. A missing normalized value means no trustworthy conversion was made.
public struct ActivityPhysicalValue: Codable, Equatable, Sendable {
  public var sourceValue: Double
  public var sourceUnit: String
  public var normalizedValue: Double?
  public var normalizedUnit: String?
  public var normalizationMethod: String?
  public var normalizationVersion: String?

  public init(
    sourceValue: Double,
    sourceUnit: String,
    normalizedValue: Double? = nil,
    normalizedUnit: String? = nil,
    normalizationMethod: String? = nil,
    normalizationVersion: String? = nil
  ) {
    self.sourceValue = sourceValue
    self.sourceUnit = sourceUnit
    self.normalizedValue = normalizedValue
    self.normalizedUnit = normalizedUnit
    self.normalizationMethod = normalizationMethod
    self.normalizationVersion = normalizationVersion
  }
}

public struct ActivityPackageEvent: Codable, Equatable, Sendable {
  public var eventType: String
  public var startDate: Date
  public var endDate: Date?
  public var source: String
  public var details: [String: String]

  public init(
    eventType: String,
    startDate: Date,
    endDate: Date? = nil,
    source: String,
    details: [String: String] = [:]
  ) {
    self.eventType = eventType
    self.startDate = startDate
    self.endDate = endDate
    self.source = source
    self.details = details
  }
}

public struct ActivityMetricSeriesDescriptor: Codable, Equatable, Sendable {
  public var seriesID: String
  public var identifier: String
  public var payloadPath: String
  public var sourceUnit: String
  public var normalizedUnit: String?
  public var aggregation: String
  public var startDate: Date?
  public var endDate: Date?
  public var sampleCount: UInt64
  public var coverageFraction: Double?
  public var source: String

  public init(
    seriesID: String,
    identifier: String,
    payloadPath: String,
    sourceUnit: String,
    normalizedUnit: String? = nil,
    aggregation: String,
    startDate: Date? = nil,
    endDate: Date? = nil,
    sampleCount: UInt64,
    coverageFraction: Double? = nil,
    source: String
  ) {
    self.seriesID = seriesID
    self.identifier = identifier
    self.payloadPath = payloadPath
    self.sourceUnit = sourceUnit
    self.normalizedUnit = normalizedUnit
    self.aggregation = aggregation
    self.startDate = startDate
    self.endDate = endDate
    self.sampleCount = sampleCount
    self.coverageFraction = coverageFraction
    self.source = source
  }
}

/// A JSONL-compatible metric sample. Original and derived values are deliberately separate.
public struct ActivityMetricSample: Codable, Equatable, Sendable {
  public var timestamp: Date
  public var endDate: Date?
  public var value: ActivityPhysicalValue
  public var sourceFlags: [String]

  public init(
    timestamp: Date,
    endDate: Date? = nil,
    value: ActivityPhysicalValue,
    sourceFlags: [String] = []
  ) {
    self.timestamp = timestamp
    self.endDate = endDate
    self.value = value
    self.sourceFlags = sourceFlags
  }
}

public struct ActivityRouteDescriptor: Codable, Equatable, Sendable {
  public var trackID: String
  public var authoritativePath: String
  public var interoperablePaths: [String]
  public var coordinateReferenceSystem: String
  public var elevationUnit: String?
  public var segmentCount: UInt64
  public var pointCount: UInt64
  public var hasTimestamps: Bool
  public var completeness: ActivityPackageCompleteness
  public var source: String

  public init(
    trackID: String,
    authoritativePath: String,
    interoperablePaths: [String] = [],
    coordinateReferenceSystem: String = "EPSG:4326",
    elevationUnit: String? = nil,
    segmentCount: UInt64,
    pointCount: UInt64,
    hasTimestamps: Bool,
    completeness: ActivityPackageCompleteness,
    source: String
  ) {
    self.trackID = trackID
    self.authoritativePath = authoritativePath
    self.interoperablePaths = interoperablePaths
    self.coordinateReferenceSystem = coordinateReferenceSystem
    self.elevationUnit = elevationUnit
    self.segmentCount = segmentCount
    self.pointCount = pointCount
    self.hasTimestamps = hasTimestamps
    self.completeness = completeness
    self.source = source
  }
}

/// A normalized route point projection. Reported elevation remains in `elevation.sourceValue`.
public struct ActivityRoutePoint: Codable, Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double
  public var timestamp: Date?
  public var originalUTCOffsetSeconds: Int?
  public var elevation: ActivityPhysicalValue?
  public var horizontalAccuracyMeters: Double?
  public var verticalAccuracyMeters: Double?
  public var speedMetersPerSecond: Double?
  public var courseDegrees: Double?
  public var segmentIndex: UInt64
  public var pointIndex: UInt64
  public var sourceFlags: [String]
  public var qualityFlags: [String]

  public init(
    latitude: Double,
    longitude: Double,
    timestamp: Date? = nil,
    originalUTCOffsetSeconds: Int? = nil,
    elevation: ActivityPhysicalValue? = nil,
    horizontalAccuracyMeters: Double? = nil,
    verticalAccuracyMeters: Double? = nil,
    speedMetersPerSecond: Double? = nil,
    courseDegrees: Double? = nil,
    segmentIndex: UInt64,
    pointIndex: UInt64,
    sourceFlags: [String] = [],
    qualityFlags: [String] = []
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.timestamp = timestamp
    self.originalUTCOffsetSeconds = originalUTCOffsetSeconds
    self.elevation = elevation
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.verticalAccuracyMeters = verticalAccuracyMeters
    self.speedMetersPerSecond = speedMetersPerSecond
    self.courseDegrees = courseDegrees
    self.segmentIndex = segmentIndex
    self.pointIndex = pointIndex
    self.sourceFlags = sourceFlags
    self.qualityFlags = qualityFlags
  }
}

public enum ActivityTransformationKind: String, Codable, Sendable {
  case none
  case timeShift
  case elevationOffset
  case smoothing
  case outlierExclusion
  case resampling
  case clipping
  case interpolation
  case manuallyDrawnEstimate
}

public struct ActivityTransformation: Codable, Equatable, Sendable {
  public var kind: ActivityTransformationKind
  public var method: String
  public var version: String
  public var reason: String
  public var parameters: [String: String]

  public init(
    kind: ActivityTransformationKind,
    method: String,
    version: String,
    reason: String,
    parameters: [String: String] = [:]
  ) {
    self.kind = kind
    self.method = method
    self.version = version
    self.reason = reason
    self.parameters = parameters
  }
}

public struct ActivityProvenanceRecord: Codable, Equatable, Sendable {
  public var recordID: UUID
  public var subjectPath: String
  public var sourceActivityID: String
  public var sourceRevision: String?
  public var originalArtifactPath: String?
  public var parserName: String
  public var parserVersion: String
  public var transformations: [ActivityTransformation]
  public var recordedAt: Date

  public init(
    recordID: UUID,
    subjectPath: String,
    sourceActivityID: String,
    sourceRevision: String? = nil,
    originalArtifactPath: String? = nil,
    parserName: String,
    parserVersion: String,
    transformations: [ActivityTransformation] = [],
    recordedAt: Date
  ) {
    self.recordID = recordID
    self.subjectPath = subjectPath
    self.sourceActivityID = sourceActivityID
    self.sourceRevision = sourceRevision
    self.originalArtifactPath = originalArtifactPath
    self.parserName = parserName
    self.parserVersion = parserVersion
    self.transformations = transformations
    self.recordedAt = recordedAt
  }
}

public struct ActivityUserAnnotation: Codable, Equatable, Sendable {
  public var key: String
  public var value: String
  public var privacyClassification: ActivityPackagePrivacyClassification
  public var modifiedAt: Date

  public init(
    key: String,
    value: String,
    privacyClassification: ActivityPackagePrivacyClassification = .privateMetadata,
    modifiedAt: Date
  ) {
    self.key = key
    self.value = value
    self.privacyClassification = privacyClassification
    self.modifiedAt = modifiedAt
  }
}
