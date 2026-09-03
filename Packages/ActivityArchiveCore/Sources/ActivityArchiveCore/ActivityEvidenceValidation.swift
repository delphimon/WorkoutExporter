import Foundation

enum ActivityEvidenceValidator {
  static func validate(
    events: [ActivityPackageEvent],
    metricSeries: [ActivityMetricSeriesDescriptor],
    routes: [ActivityRouteDescriptor],
    provenance: [ActivityProvenanceRecord],
    userAnnotations: [ActivityUserAnnotation],
    files: [ActivityPackageFileEntry]
  ) throws {
    try validateEvents(events)
    try validateMetricSeries(metricSeries)
    try validateRoutes(routes)
    try validateProvenance(provenance)
    try validateAnnotations(userAnnotations)
    try validateReferences(
      metricSeries: metricSeries,
      routes: routes,
      provenance: provenance,
      files: files
    )
  }

  private static func validateEvents(_ events: [ActivityPackageEvent]) throws {
    for event in events {
      guard !event.eventType.isEmpty,
        !event.source.isEmpty,
        event.endDate.map({ $0 >= event.startDate }) ?? true
      else {
        throw ActivityPackageError.invalidManifest("Invalid workout event")
      }
    }
  }

  private static func validateMetricSeries(_ series: [ActivityMetricSeriesDescriptor]) throws {
    var identifiers = Set<String>()
    for item in series {
      let path = try ActivityPackagePath.validated(item.payloadPath)
      guard !item.seriesID.isEmpty,
        identifiers.insert(item.seriesID).inserted,
        !item.identifier.isEmpty,
        !path.isEmpty,
        !item.sourceUnit.isEmpty,
        item.normalizedUnit.map({ !$0.isEmpty }) ?? true,
        !item.aggregation.isEmpty,
        !item.source.isEmpty,
        datesAreOrdered(start: item.startDate, end: item.endDate),
        item.coverageFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true
      else {
        throw ActivityPackageError.invalidManifest("Invalid metric-series descriptor")
      }
    }
  }

  private static func validateRoutes(_ routes: [ActivityRouteDescriptor]) throws {
    var identifiers = Set<String>()
    for route in routes {
      _ = try ActivityPackagePath.validated(route.authoritativePath)
      for path in route.interoperablePaths {
        _ = try ActivityPackagePath.validated(path)
      }
      guard !route.trackID.isEmpty,
        identifiers.insert(route.trackID).inserted,
        !route.coordinateReferenceSystem.isEmpty,
        route.elevationUnit.map({ !$0.isEmpty }) ?? true,
        !route.source.isEmpty
      else {
        throw ActivityPackageError.invalidManifest("Invalid route descriptor")
      }
    }
  }

  private static func validateProvenance(_ records: [ActivityProvenanceRecord]) throws {
    var identifiers = Set<UUID>()
    for record in records {
      _ = try ActivityPackagePath.validated(record.subjectPath)
      if let path = record.originalArtifactPath {
        _ = try ActivityPackagePath.validated(path)
      }
      guard identifiers.insert(record.recordID).inserted,
        !record.sourceActivityID.isEmpty,
        !record.parserName.isEmpty,
        !record.parserVersion.isEmpty,
        record.transformations.allSatisfy({ transformation in
          !transformation.method.isEmpty
            && !transformation.version.isEmpty
            && !transformation.reason.isEmpty
        })
      else {
        throw ActivityPackageError.invalidManifest("Invalid provenance record")
      }
    }
  }

  private static func validateAnnotations(_ annotations: [ActivityUserAnnotation]) throws {
    guard annotations.allSatisfy({ !$0.key.isEmpty }) else {
      throw ActivityPackageError.invalidManifest("Annotation keys cannot be empty")
    }
  }

  private static func validateReferences(
    metricSeries: [ActivityMetricSeriesDescriptor],
    routes: [ActivityRouteDescriptor],
    provenance: [ActivityProvenanceRecord],
    files: [ActivityPackageFileEntry]
  ) throws {
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    for series in metricSeries {
      guard filesByPath[series.payloadPath]?.role == .metricSeries else {
        throw ActivityPackageError.invalidManifest(
          "Metric series does not reference a metric payload: \(series.payloadPath)"
        )
      }
    }
    for route in routes {
      guard let authoritative = filesByPath[route.authoritativePath],
        authoritative.role == .authoritativeRoute,
        authoritative.authority == .authoritative
      else {
        throw ActivityPackageError.invalidManifest(
          "Route does not reference an authoritative route payload"
        )
      }
      for path in route.interoperablePaths {
        guard let interoperable = filesByPath[path], interoperable.role == .interoperableRoute
        else {
          throw ActivityPackageError.invalidManifest(
            "Route does not reference an interoperable route payload: \(path)"
          )
        }
      }
    }
    for record in provenance {
      guard filesByPath[record.subjectPath] != nil else {
        throw ActivityPackageError.invalidManifest(
          "Provenance subject is not present: \(record.subjectPath)"
        )
      }
      if let path = record.originalArtifactPath, filesByPath[path] == nil {
        throw ActivityPackageError.invalidManifest(
          "Original provenance artifact is not present: \(path)"
        )
      }
    }
  }

  private static func datesAreOrdered(start: Date?, end: Date?) -> Bool {
    guard let start, let end else { return true }
    return end >= start
  }
}
