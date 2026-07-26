import Charts
import MapKit
import SwiftUI

struct WorkoutDetailView: View {
    let workout: WorkoutSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @State private var model = WorkoutDetailViewModel()
    @State private var selectedSection = DetailSection.summary
    @State private var showExport = false
    @State private var showLocationEditor = false
    @State private var selectedDate: Date?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: 0) {
                    detailPicker
                    ScrollView {
                        if selectedSection == .summary {
                            SummarySection(
                                summary: workout,
                                detail: nil,
                                units: settings.distanceUnits,
                                editLocation: { showLocationEditor = true }
                            )
                            ProgressView("Loading charts, route, and samples…")
                                .padding()
                        } else {
                            ProgressView("Loading workout details…")
                                .frame(maxWidth: .infinity, minHeight: 360)
                        }
                    }
                }
            case .failed(let message):
                VStack(spacing: 0) {
                    detailPicker
                    ScrollView {
                        SummarySection(
                            summary: workout,
                            detail: nil,
                            units: settings.distanceUnits,
                            editLocation: { showLocationEditor = true }
                        )
                        ContentUnavailableView(
                            "Additional Detail Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                    }
                }
            case .loaded(let detail):
                detailContent(detail)
            }
        }
        .navigationTitle(workout.activityName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
                .disabled(!detailIsLoaded)
                .accessibilityIdentifier("workout-export-button")
        }
        .sheet(isPresented: $showExport) {
            if case .loaded(let detail) = model.state {
                ExportView(requests: [.loaded(detail)])
            }
        }
        .sheet(isPresented: $showLocationEditor) {
            WorkoutLocationTagEditor(workout: workout)
        }
        .task {
            await model.load(id: workout.id, client: environment.healthClient, settings: settings.metricSettings)
        }
    }

    private func detailContent(_ detail: WorkoutDetail) -> some View {
        VStack(spacing: 0) {
            detailPicker

            ScrollView {
                switch selectedSection {
                case .summary:
                    SummarySection(
                        summary: detail.summary,
                        detail: detail,
                        units: settings.distanceUnits,
                        editLocation: { showLocationEditor = true }
                    )
                case .map:
                    RouteMapSection(
                        detail: detail,
                        presentation: model.chartPresentation,
                        selectedDate: $selectedDate,
                        editLocation: { showLocationEditor = true }
                    )
                case .heartRate:
                    HeartRateSection(
                        detail: detail,
                        presentation: model.chartPresentation,
                        units: settings.distanceUnits,
                        selectedDate: $selectedDate
                    )
                case .pace:
                    PaceSection(
                        detail: detail,
                        presentation: model.chartPresentation,
                        units: settings.distanceUnits,
                        selectedDate: $selectedDate
                    )
                case .elevation:
                    ElevationSection(
                        detail: detail,
                        presentation: model.chartPresentation,
                        units: settings.distanceUnits,
                        selectedDate: $selectedDate
                    )
                case .splits: SplitsSection(detail: detail, units: settings.distanceUnits)
                case .raw: RawDataSection(detail: detail)
                case .export:
                    Button("Configure Export", systemImage: "square.and.arrow.up") {
                        showExport = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                }
            }
        }
    }

    private var detailPicker: some View {
        Picker("Detail section", selection: $selectedSection) {
            ForEach(DetailSection.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .accessibilityIdentifier("detail-section-picker")
    }

    private var detailIsLoaded: Bool {
        if case .loaded = model.state { return true }
        return false
    }
}

private enum DetailSection: String, CaseIterable, Identifiable {
    case summary, map, heartRate, pace, elevation, splits, raw, export
    var id: String { rawValue }
    var label: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .raw: "Raw Data"
        default: rawValue.capitalized
        }
    }
}

private struct SummarySection: View {
    let summary: WorkoutSummary
    let detail: WorkoutDetail?
    let units: DistanceUnitPreference
    let editLocation: () -> Void

    var body: some View {
        WorkoutLocationTagCard(
            workout: summary,
            editLocation: editLocation
        )
        .padding(.horizontal)
        .padding(.top)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCard("Duration", MeasurementFormatterFactory.duration(summary.duration), "clock")
            MetricCard("Workout Distance", MeasurementFormatterFactory.distance(summary.totalDistanceMeters, preference: units), "figure.run")
            MetricCard("GPS-Derived Distance", MeasurementFormatterFactory.distance(detail?.derived.routeDistanceMeters?.value, preference: units), "location")
            MetricCard("Moving Time", detail?.derived.eventAwareMovingTime.map { MeasurementFormatterFactory.duration($0.value) } ?? "—", "pause.circle")
            MetricCard("Average Heart Rate", detail?.derived.averageHeartRateBPM.map { "\(Int($0.value.rounded())) bpm" } ?? summary.averageHeartRateBPM.map { "\(Int($0.rounded())) bpm" } ?? "—", "heart")
            MetricCard("Workout Elevation Gain", MeasurementFormatterFactory.elevation(summary.elevationGainMeters, preference: units), "mountain.2")
        }
        .padding()

        if let detail, !detail.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Data Notes", systemImage: "info.circle")
                    .font(.headline)
                ForEach(Array(Set(detail.warnings)).sorted(), id: \.self) {
                    Text($0).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    init(_ title: String, _ value: String, _ icon: String) {
        self.title = title
        self.value = value
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutLocationTagCard: View {
    let workout: WorkoutSummary
    let editLocation: () -> Void
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Location tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(locationName ?? "No location tag")
                    .font(.headline)
            }
            Spacer()
            Button("Edit", action: editLocation)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("edit-detail-location-tag-button")
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task(id: workout.id) {
            environment.routePresentationStore.enqueue(
                workout: workout,
                client: environment.healthClient
            )
        }
    }

    private var locationName: String? {
        if let custom = environment.workoutMetadataStore.customLocationTag(
            for: workout.id
        ) {
            return custom
        }
        guard case .loaded(let presentation) =
                environment.routePresentationStore.state(for: workout.id) else {
            return nil
        }
        return presentation.placeLabel?.name
    }
}

private struct RouteMapSection: View {
    let detail: WorkoutDetail
    let presentation: WorkoutChartPresentation?
    @Binding var selectedDate: Date?
    let editLocation: () -> Void

    var body: some View {
        WorkoutLocationTagCard(
            workout: detail.summary,
            editLocation: editLocation
        )
        .padding([.horizontal, .top])

        if let presentation, presentation.routePoints.isEmpty {
            ContentUnavailableView("No GPS Route", systemImage: "map", description: Text("Other workout details remain available."))
                .frame(minHeight: 400)
        } else if let presentation {
            SynchronizedRouteMap(
                presentation: presentation,
                selectedDate: selectedDate
            )
                .frame(minHeight: 500)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
        } else {
            ProgressView("Preparing route…")
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

private struct SynchronizedRouteContext: View {
    let detail: WorkoutDetail
    let presentation: WorkoutChartPresentation
    @Binding var selectedDate: Date?
    let units: DistanceUnitPreference

    var body: some View {
        if !presentation.routePoints.isEmpty {
            SynchronizedRouteMap(
                presentation: presentation,
                selectedDate: selectedDate
            )
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if let selectedDate {
                HStack {
                    Label(elapsedTime(for: selectedDate), systemImage: "clock")
                    Spacer()
                    Label(
                        selectedDistance(for: selectedDate),
                        systemImage: "arrow.left.and.right"
                    )
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Touch and slide across the chart to inspect a time and map position.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func elapsedTime(for date: Date) -> String {
        MeasurementFormatterFactory.duration(
            max(0, date.timeIntervalSince(detail.summary.startDate))
        )
    }

    private func selectedDistance(for date: Date) -> String {
        let point = presentation.nearestRouteMetric(to: date)
        return MeasurementFormatterFactory.distance(
            point?.cumulativeDistanceMeters,
            preference: units
        )
    }
}

private struct SynchronizedRouteMap: View {
    let presentation: WorkoutChartPresentation
    let selectedDate: Date?

    var body: some View {
        Map(initialPosition: .rect(routeMapRect)) {
            ForEach(presentation.mapRoutes) { route in
                MapPolyline(
                    coordinates: route.points.map {
                        CLLocationCoordinate2D(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
                .stroke(.blue, lineWidth: 4)
            }
            if let first = presentation.routePoints.first {
                Marker(
                    "Start",
                    systemImage: "flag.fill",
                    coordinate: .init(latitude: first.latitude, longitude: first.longitude)
                )
                .tint(.green)
            }
            if let last = presentation.routePoints.last {
                Marker(
                    "Finish",
                    systemImage: "flag.checkered",
                    coordinate: .init(latitude: last.latitude, longitude: last.longitude)
                )
                .tint(.red)
            }
            if let selectedPoint {
                Marker(
                    "Selected position",
                    systemImage: "circle.fill",
                    coordinate: .init(
                        latitude: selectedPoint.latitude,
                        longitude: selectedPoint.longitude
                    )
                )
                .tint(.orange)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .accessibilityIdentifier("synchronized-route-map")
    }

    private var selectedPoint: RoutePoint? {
        guard let selectedDate else { return nil }
        return presentation.nearestRoutePoint(to: selectedDate)
    }

    private var routeMapRect: MKMapRect {
        guard let bounds = presentation.routeBounds else { return .world }
        let northWest = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: bounds.maximumLatitude,
                longitude: bounds.minimumLongitude
            )
        )
        let southEast = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: bounds.minimumLatitude,
                longitude: bounds.maximumLongitude
            )
        )
        let rect = MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
        let xPadding = max(rect.width * 0.15, 500)
        let yPadding = max(rect.height * 0.15, 500)
        return rect.insetBy(dx: -xPadding, dy: -yPadding)
    }
}

private struct HeartRateSection: View {
    let detail: WorkoutDetail
    let presentation: WorkoutChartPresentation?
    let units: DistanceUnitPreference
    @Binding var selectedDate: Date?

    var body: some View {
        if let presentation, presentation.heartRateSamples.isEmpty {
            ContentUnavailableView("No Heart-Rate Data", systemImage: "heart.slash", description: Text("The route and other workout data are still available."))
                .frame(minHeight: 400)
        } else if let presentation {
            SynchronizedRouteContext(
                detail: detail,
                presentation: presentation,
                selectedDate: $selectedDate,
                units: units
            )
            .padding([.horizontal, .top])

            let selectedSample = selectedDate.flatMap {
                presentation.nearestHeartRateSample(to: $0)
            }
            Chart {
                ForEach(presentation.heartRateSamples) { sample in
                    LineMark(
                        x: .value("Time", sample.startDate),
                        y: .value("BPM", sample.value)
                    )
                    .foregroundStyle(.red)
                }
                if let selectedSample {
                    RuleMark(
                        x: .value(
                            "Selected time",
                            selectedSample.startDate
                        )
                    )
                        .foregroundStyle(.secondary)
                    PointMark(
                        x: .value("Selected time", selectedSample.startDate),
                        y: .value("BPM", selectedSample.value)
                    )
                    .foregroundStyle(.red)
                    .annotation(position: .top) {
                        Text("\(Int(selectedSample.value.rounded())) bpm")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxisLabel("beats/min")
            .frame(height: 320)
            .padding()

            HStack {
                MetricCard("Minimum", "\(Int(detail.derived.minimumHeartRateBPM?.value.rounded() ?? 0)) bpm", "arrow.down")
                MetricCard("Maximum", "\(Int(detail.derived.maximumHeartRateBPM?.value.rounded() ?? 0)) bpm", "arrow.up")
            }
            .padding(.horizontal)

            if let zones = detail.derived.heartRateZones {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Time in Heart-Rate Zones").font(.headline)
                    ForEach(zones) { zone in
                        LabeledContent(
                            "Zone \(zone.zone)",
                            value: MeasurementFormatterFactory.duration(zone.duration)
                        )
                    }
                    Text("Personal analysis only; not medical guidance.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        } else {
            ProgressView("Preparing chart…")
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

private struct PaceSection: View {
    let detail: WorkoutDetail
    let presentation: WorkoutChartPresentation?
    let units: DistanceUnitPreference
    @Binding var selectedDate: Date?

    var body: some View {
        VStack(spacing: 12) {
            if let presentation, !presentation.pacePoints.isEmpty {
                SynchronizedRouteContext(
                    detail: detail,
                    presentation: presentation,
                    selectedDate: $selectedDate,
                    units: units
                )
                let selectedPoint = selectedDate.flatMap {
                    presentation.nearestPacePoint(to: $0)
                }
                Chart {
                    ForEach(presentation.pacePoints) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value(
                                "Pace",
                                displayPaceMinutes(
                                    point.speedMetersPerSecond
                                )
                            )
                        )
                    }
                    if let selectedPoint {
                        RuleMark(
                            x: .value(
                                "Selected time",
                                selectedPoint.timestamp
                            )
                        )
                            .foregroundStyle(.secondary)
                        PointMark(
                            x: .value(
                                "Selected time",
                                selectedPoint.timestamp
                            ),
                            y: .value(
                                "Pace",
                                displayPaceMinutes(
                                    selectedPoint.speedMetersPerSecond
                                )
                            )
                        )
                        .annotation(position: .top) {
                            Text(
                                selectedPace(
                                    speedMetersPerSecond:
                                        selectedPoint.speedMetersPerSecond
                                )
                            )
                            .font(.caption.bold())
                            .padding(6)
                            .background(.regularMaterial, in: Capsule())
                        }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxisLabel("min/\(units.paceUnitLabel)")
                .frame(height: 280)
            } else if presentation == nil {
                ProgressView("Preparing chart…")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                ContentUnavailableView(
                    "No Pace Data",
                    systemImage: "figure.walk.motion"
                )
                .frame(minHeight: 400)
            }
            MetricCard("Elapsed Pace", elapsedPace, "timer")
            MetricCard("Moving Pace", movingPace, "figure.run")
            MetricCard(
                "Maximum Speed",
                MeasurementFormatterFactory.speed(
                    detail.derived.maximumSpeedMetersPerSecond?.value,
                    preference: units
                ),
                "speedometer"
            )
        }
        .padding()
    }

    private var elapsedPace: String {
        let distance = detail.summary.totalDistanceMeters
        let pace = distance.flatMap { value in
            value > 0 ? detail.summary.duration / (value / 1_000) : nil
        }
        return MeasurementFormatterFactory.pace(secondsPerKilometer: pace, preference: units)
    }

    private var movingPace: String {
        guard let time = detail.derived.speedThresholdMovingTime?.value,
              let distance = detail.summary.totalDistanceMeters,
              distance > 0 else {
            return "—"
        }
        return MeasurementFormatterFactory.pace(
            secondsPerKilometer: time / (distance / 1_000),
            preference: units
        )
    }

    private func displayPaceMinutes(_ metersPerSecond: Double?) -> Double {
        guard let metersPerSecond, metersPerSecond > 0 else { return 0 }
        let secondsPerKilometer = 1_000 / metersPerSecond
        let seconds = units == .metric
            ? secondsPerKilometer
            : secondsPerKilometer * 1.609_344
        return seconds / 60
    }

    private func selectedPace(speedMetersPerSecond: Double?) -> String {
        guard let speedMetersPerSecond, speedMetersPerSecond > 0 else {
            return "—"
        }
        return MeasurementFormatterFactory.pace(
            secondsPerKilometer: 1_000 / speedMetersPerSecond,
            preference: units
        )
    }
}

private struct ElevationSection: View {
    let detail: WorkoutDetail
    let presentation: WorkoutChartPresentation?
    let units: DistanceUnitPreference
    @Binding var selectedDate: Date?

    var body: some View {
        if let presentation, presentation.elevationPoints.isEmpty {
            ContentUnavailableView("No Elevation Data", systemImage: "mountain.2")
        } else if let presentation {
            SynchronizedRouteContext(
                detail: detail,
                presentation: presentation,
                selectedDate: $selectedDate,
                units: units
            )
            .padding([.horizontal, .top])

            let selectedPoint = selectedDate.flatMap {
                presentation.nearestElevationPoint(to: $0)
            }
            Chart {
                ForEach(presentation.elevationPoints) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value(
                            "Altitude",
                            displayAltitude(point.altitudeMeters)
                        )
                    )
                    .foregroundStyle(.green.opacity(0.5))
                }
                if let selectedPoint {
                    RuleMark(
                        x: .value(
                            "Selected time",
                            selectedPoint.timestamp
                        )
                    )
                        .foregroundStyle(.secondary)
                    PointMark(
                        x: .value(
                            "Selected time",
                            selectedPoint.timestamp
                        ),
                        y: .value(
                            "Altitude",
                            displayAltitude(selectedPoint.altitudeMeters)
                        )
                    )
                    .foregroundStyle(.green)
                    .annotation(position: .top) {
                        Text(
                            MeasurementFormatterFactory.elevation(
                                selectedPoint.altitudeMeters,
                                preference: units
                            )
                        )
                        .font(.caption.bold())
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxisLabel(units == .metric ? "meters" : "feet")
            .frame(height: 320)
            .padding()
            MetricCard(
                "Recorded Workout Gain",
                MeasurementFormatterFactory.elevation(detail.summary.elevationGainMeters, preference: units),
                "mountain.2"
            )
            .padding()
        } else {
            ProgressView("Preparing chart…")
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    private func displayAltitude(_ meters: Double) -> Double {
        Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: units.elevationUnit)
            .value
    }
}

private struct SplitsSection: View {
    let detail: WorkoutDetail
    let units: DistanceUnitPreference

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(detail.derived.splits) { split in
                HStack {
                    Text("\(split.index)").font(.headline).frame(width: 30)
                    VStack(alignment: .leading) {
                        Text(MeasurementFormatterFactory.distance(split.distanceMeters, preference: units))
                        Text(MeasurementFormatterFactory.duration(split.elapsedTime))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MeasurementFormatterFactory.pace(secondsPerKilometer: split.paceSecondsPerKilometer, preference: units))
                        .monospacedDigit()
                }
                .padding()
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct RawDataSection: View {
    let detail: WorkoutDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(detail.samples.count.formatted()) quantity samples")
            Text("\(detail.categorySamples.count.formatted()) category samples")
            Text("\(detail.routePoints.count.formatted()) route points across \(detail.routes.count) route object(s)")
            Text("\(detail.events.count.formatted()) workout events")
            Text("\(detail.statistics.count.formatted()) native statistics")
            Divider()
            ForEach(detail.samples.prefix(100)) { sample in
                VStack(alignment: .leading) {
                    Text(sample.typeIdentifier).font(.caption.bold())
                    Text("\(sample.value) \(sample.unit) · \(sample.startDate.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if detail.samples.count > 100 {
                Text("Showing 100 of \(detail.samples.count) samples. The complete original series is retained for export.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
