import ActivityArchiveCore
import Foundation

/// Search input is literal text; values never become SQL syntax.
public struct ActivityCatalogFilter: Equatable, Sendable {
  public var search = ""
  public var source = ""
  public var activityType = ""
  public var from: Date?
  public var through: Date?
  public var routeState: String?
  public var metricsState: String?
  public var completeness: String?
  public var importStatus: ActivityImportStatus?
  public var hasWarnings: Bool?
  public init() {}
}

public struct ActivityCatalogCursor: Equatable, Sendable {
  public let timestamp: Double
  public let id: Int64
  public init(timestamp: Double, id: Int64) {
    self.timestamp = timestamp
    self.id = id
  }
}

public struct ActivityImportCursor: Equatable, Sendable {
  public let timestamp: Double
  public let id: UUID
  public init(timestamp: Double, id: UUID) {
    self.timestamp = timestamp
    self.id = id
  }
}

public struct ActivityCatalogPage: Sendable {
  public let observations: [ActivitySourceObservation]
  public let next: ActivityCatalogCursor?
}

public struct ActivityImportPage: Sendable {
  public let jobs: [ActivityImportJob]
  public let next: ActivityImportCursor?
}

public struct ActivityObservationDetail: Sendable {
  public let observation: ActivitySourceObservation
  public let statistics: [ActivityPackageStatistic]
  public let routes: [ActivitySourceRouteSummary]
  public let deviceName: String?
  public let deviceModel: String?
  public let originalIdentifier: String?
  public let warnings: [ActivityImportWarning]
}
