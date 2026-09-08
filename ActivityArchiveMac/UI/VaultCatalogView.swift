import ActivityArchiveCore
import ActivityArchiveVault
import MapKit
import SwiftUI

struct VaultCatalogView: View {
  @Bindable var model: VaultCatalogModel
  @State private var selection: Int64?
  @State private var customary = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Source Activities").font(.largeTitle.bold())
      Text("Immutable source observations. Canonical selections and totals will be separate.")
        .foregroundStyle(.secondary).accessibilityIdentifier("source-observation-notice")
      CatalogFilters(filter: $model.filter, imports: false)
      catalogStatus(model: model, imports: false)
      HSplitView {
        List(model.activities, selection: $selection) { observation in
          VStack(alignment: .leading, spacing: 4) {
            Text(observation.workoutTypeName).font(.headline)
            if let title = observation.title { Text(title) }
            Text(observation.sourceName).foregroundStyle(.secondary)
            Text(observation.startDate.map(sourceDate) ?? "Source date unavailable").font(.caption)
            Text("Route: \(observation.routeState) · Metrics: \(observation.metricsState)").font(
              .caption)
          }
          .tag(observation.id)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("source-row-\(observation.id)")
        }
        .frame(minWidth: 240, idealWidth: 300)
        .accessibilityIdentifier("source-activity-list")
        ScrollView {
          if let detail = model.detail {
            observationDetail(detail).padding()
          } else {
            ContentUnavailableView(
              "Choose a source observation", systemImage: "figure.hiking",
              description: Text("Review its original identity, values and route."))
          }
        }.frame(minWidth: 330)
      }
      .task(id: selection) { await model.select(selection) }
    }
    .padding(20)
    .task(id: model.filter) {
      selection = nil
      await model.refresh(imports: false)
    }
  }

  private func observationDetail(_ detail: ActivityObservationDetail) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(detail.observation.workoutTypeName).font(.title.bold())
      if let title = detail.observation.title { LabeledContent("Title / location", value: title) }
      GroupBox("Source evidence") {
        VStack(alignment: .leading, spacing: 8) {
          evidence("Source activity ID", detail.observation.sourceActivityID)
          evidence("Original identifier", detail.originalIdentifier ?? "Not reported")
          evidence("App", detail.observation.sourceName)
          evidence("Bundle", detail.observation.sourceBundleIdentifier ?? "Not reported")
          evidence("Device", detail.deviceName ?? "Not reported")
          evidence("Device model", detail.deviceModel ?? "Not reported")
          evidence("Start", detail.observation.startDate.map(sourceDate) ?? "Not reported")
          evidence("End", detail.observation.endDate.map(sourceDate) ?? "Not reported")
          evidence("Time zone", detail.observation.timeZoneIdentifier ?? "Not reported")
          evidence("Imported", sourceDate(detail.observation.importedAt))
          evidence("Import state", "Imported immutable observation")
          evidence("Completeness", detail.observation.completeness)
          evidence("Route", detail.observation.routeState)
          evidence("Metrics", detail.observation.metricsState)
          evidence("Package revision", "\(detail.observation.packageRevision)")
          evidence("Package ID", detail.observation.packageID.uuidString)
          evidence("Object SHA-256", detail.observation.objectHash)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("Source-reported statistics — exact values and units") {
        VStack(alignment: .leading, spacing: 12) {
          if detail.statistics.isEmpty { Text("No source-reported statistics were supplied.") }
          ForEach(Array(detail.statistics.enumerated()), id: \.offset) { _, statistic in
            VStack(alignment: .leading, spacing: 3) {
              Text("\(statistic.identifier) (\(statistic.aggregation))").bold()
              Text("\(String(statistic.value)) \(statistic.unit)")
              Text(statistic.provenance).font(.caption).foregroundStyle(.secondary)
              if let display = lengthDisplay(statistic) {
                Text("Display conversion: \(display)").font(.caption)
              }
            }
          }
          Toggle("US customary display conversions", isOn: $customary)
            .accessibilityIdentifier("catalog-customary-units")
          Text(
            "Display conversion v1 references the source statistic above; it is never stored as source evidence. Other units remain as reported."
          )
          .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.accessibilityIdentifier("source-statistics")
      if !detail.warnings.isEmpty {
        GroupBox("Source warnings") {
          ForEach(detail.warnings) { warning in
            Label(warning.message, systemImage: "exclamationmark.triangle")
          }
        }
      }
      ForEach(detail.routes) { route in
        Text("\(route.trackID): \(route.pointCount) source points")
          .font(.caption)
      }
      HStack {
        Button("Load Source Overlay") { model.loadRoute() }
          .disabled(model.isLoadingRoute || detail.routes.isEmpty)
          .accessibilityIdentifier("load-source-overlay")
        if model.isLoadingRoute {
          ProgressView().controlSize(.small)
          Button("Cancel Route") { model.cancelRoute() }
        }
      }
      Menu("Compare another source on this page") {
        ForEach(
          model.activities.filter { $0.id != detail.observation.id && $0.routeState == "included" }
        ) { other in
          Button("\(other.sourceName) · \(other.title ?? other.workoutTypeName) · \(other.id)") {
            model.loadRoute(comparing: other)
          }
        }
      }.disabled(model.isLoadingRoute || detail.routes.isEmpty)
      Text(
        "Loading an overlay uses Apple Maps for the displayed region. Source files stay in this vault."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let route = model.route {
        SourceRouteMap(first: route, second: model.comparisonRoute)
          .frame(height: 300)
        Label("Solid line: \(detail.observation.sourceName)", systemImage: "line.diagonal")
        if let name = model.comparisonName, let comparison = model.comparisonRoute {
          Label("Dashed line: \(name)", systemImage: "line.diagonal")
          Text(
            "Comparison display derivative: \(comparison.algorithmVersion), object \(comparison.sourceObjectHash), \(comparison.displayedPointCount) / \(comparison.sourcePointCount) points."
          )
          .font(.caption)
        }
        Text(
          "Display derivative · \(route.algorithmVersion) · \(route.displayedPointCount) displayed / \(route.sourcePointCount) original points. Segment boundaries and source order are retained; original geometry is unchanged."
        )
        .font(.caption).accessibilityIdentifier("route-derivative-notice")
      }
    }
    .textSelection(.enabled)
  }

  private func evidence(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.callout)
    }
  }

  private func lengthDisplay(_ statistic: ActivityPackageStatistic) -> String? {
    let units: [String: UnitLength] = ["m": .meters, "km": .kilometers, "mi": .miles, "ft": .feet]
    guard let unit = units[statistic.unit] else { return nil }
    let elevation =
      statistic.identifier.lowercased().contains("elevation")
      || statistic.identifier.lowercased().contains("ascent")
    let target: UnitLength =
      customary ? (elevation ? .feet : .miles) : (elevation ? .meters : .kilometers)
    let result = Measurement(value: statistic.value, unit: unit).converted(to: target)
    return "\(result.value.formatted(.number.precision(.fractionLength(0...3)))) \(target.symbol)"
  }
}

private struct SourceRouteMap: View {
  let first: ActivityRouteDisplay
  let second: ActivityRouteDisplay?
  var body: some View {
    Map {
      ForEach(first.segments) { segment in
        MapPolyline(
          coordinates: segment.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
          }
        )
        .stroke(.blue, lineWidth: 3)
      }
      if let second {
        ForEach(second.segments) { segment in
          MapPolyline(
            coordinates: segment.points.map {
              CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
          )
          .stroke(.orange, style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
        }
      }
    }
    .mapControls {
      MapZoomStepper()
      MapCompass()
    }
    .accessibilityLabel(
      "Source route overlays. First source uses a solid line; comparison uses a dashed line. Display geometry is a derivative, not a canonical selection."
    )
    .accessibilityIdentifier("source-route-map")
  }
}

struct CatalogFilters: View {
  @Binding var filter: ActivityCatalogFilter
  let imports: Bool
  @State private var useDates = false
  @State private var from = Date.now.addingTimeInterval(-30 * 86400)
  @State private var through = Date.now

  var body: some View {
    VStack(alignment: .leading) {
      TextField(
        imports
          ? "Search filenames, errors or object hashes"
          : "Search titles, source identities, apps or types", text: $filter.search
      )
      .textFieldStyle(.roundedBorder).accessibilityIdentifier("catalog-search")
      DisclosureGroup("Filters") {
        VStack(alignment: .leading) {
          if !imports {
            TextField("Exact source app name", text: $filter.source).accessibilityIdentifier(
              "catalog-source-filter")
            TextField("Exact activity type", text: $filter.activityType).accessibilityIdentifier(
              "catalog-type-filter")
            HStack {
              statePicker(
                "Route", selection: $filter.routeState,
                values: ["included", "pending", "unavailable", "intentionallyExcluded"])
              statePicker(
                "Metrics", selection: $filter.metricsState,
                values: ["included", "partial", "unavailable", "intentionallyExcluded"])
              statePicker(
                "Completeness", selection: $filter.completeness,
                values: ["final", "provisional", "tombstone"])
            }
          }
          HStack {
            Picker("Import state", selection: $filter.importStatus) {
              Text("Any").tag(ActivityImportStatus?.none)
              ForEach(ActivityImportStatus.allCases, id: \.self) {
                Text($0.rawValue).tag(Optional($0))
              }
            }.accessibilityIdentifier("catalog-status-filter")
            Picker("Warnings", selection: $filter.hasWarnings) {
              Text("Any").tag(Bool?.none)
              Text("Has warnings").tag(Optional(true))
              Text("No warnings").tag(Optional(false))
            }
          }
          Toggle(
            imports ? "Filter import dates" : "Filter source dates (excludes unknown dates)",
            isOn: $useDates)
          if useDates {
            HStack {
              DatePicker("From", selection: $from)
              DatePicker("Through", selection: $through)
            }
          }
          Button("Clear Filters") {
            filter = ActivityCatalogFilter()
            useDates = false
          }
        }.padding(.top, 8)
      }
    }
    .onChange(of: useDates) { _, enabled in
      filter.from = enabled ? from : nil
      filter.through = enabled ? through : nil
    }
    .onChange(of: from) { _, value in if useDates { filter.from = value } }
    .onChange(of: through) { _, value in if useDates { filter.through = value } }
  }

  private func statePicker(_ label: String, selection: Binding<String?>, values: [String])
    -> some View
  {
    Picker(label, selection: selection) {
      Text("Any").tag(String?.none)
      ForEach(values, id: \.self) { Text($0).tag(Optional($0)) }
    }
  }
}

@MainActor
func catalogStatus(model: VaultCatalogModel, imports: Bool) -> some View {
  VStack(alignment: .leading) {
    if let error = model.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle").accessibilityIdentifier("catalog-error")
    }
    HStack {
      if model.isLoading {
        ProgressView().controlSize(.small).accessibilityLabel("Loading catalog page")
      }
      Text("\(imports ? model.jobs.count : model.activities.count) on this page")
        .accessibilityIdentifier("catalog-page-status")
      Button("First Page / Retry") { Task { await model.refresh(imports: imports) } }
      Button("Next Page") { Task { await model.refresh(imports: imports, next: true) } }
        .disabled(
          model.isLoading || (imports ? model.nextImport == nil : model.nextActivity == nil)
        )
        .accessibilityIdentifier("catalog-next-page")
    }
  }
}

func sourceDate(_ date: Date) -> String {
  date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}
