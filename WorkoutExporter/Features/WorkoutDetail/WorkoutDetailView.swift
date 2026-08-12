import Charts
import MapKit
import SwiftUI
import UIKit

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
                ExportView(
                    requests: [
                        .loaded(
                            detail,
                            locationTag: environment.workoutMetadataStore
                                .customLocationTag(for: detail.id),
                            wasExported: environment.workoutMetadataStore
                                .isExported(detail.id)
                        )
                    ]
                )
            }
        }
        .sheet(isPresented: $showLocationEditor) {
            WorkoutLocationTagEditor(workout: workout)
        }
        .task {
            await model.load(
                id: workout.id,
                referenceDate: workout.startDate,
                client: environment.healthClient,
                settings: settings.metricSettings
            )
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
            if let energy = summary.activeEnergyKilocalories {
                MetricCard(
                    "Active Energy", "\(Int(energy.rounded()).formatted()) kcal", "flame")
            }
            if let distance = summary.totalDistanceMeters {
                MetricCard(
                    "Workout Distance",
                    MeasurementFormatterFactory.distance(distance, preference: units),
                    WorkoutActivityCatalog.symbolName(
                        for: summary.activityIdentifier,
                        fallbackName: summary.activityName
                    )
                )
            }
            if let distance = detail?.derived.routeDistanceMeters?.value {
                MetricCard(
                    "GPS-Derived Distance",
                    MeasurementFormatterFactory.distance(distance, preference: units),
                    "location"
                )
            }
            if summary.hasRoute, let movingTime = detail?.derived.eventAwareMovingTime?.value {
                MetricCard(
                    "Moving Time",
                    MeasurementFormatterFactory.duration(movingTime),
                    "pause.circle"
                )
            }
            if let heartRate = detail?.derived.averageHeartRateBPM?.value
                ?? summary.averageHeartRateBPM {
                MetricCard(
                    "Average Heart Rate", "\(Int(heartRate.rounded())) bpm", "heart")
            }
            if let elevation = summary.elevationGainMeters {
                MetricCard(
                    "Workout Elevation Gain",
                    MeasurementFormatterFactory.elevation(elevation, preference: units),
                    "mountain.2"
                )
            }
        }
        .padding()

        if let detail, !detail.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Data Notes", systemImage: "info.circle")
                    .font(.headline)
                ForEach(Array(Set(detail.warnings)).sorted(), id: \.self) { warning in
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            warning.contains("not explicitly associated with this workout")
                                ? "time-matched-heart-rate-note"
                                : "workout-data-note"
                        )
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
                selectedDate: displayedDate
            )
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }

        HStack(spacing: 8) {
            Label(elapsedTime(for: displayedDate), systemImage: "timer")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chart-elapsed-time")
            Label(actualTime(for: displayedDate), systemImage: "clock")
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chart-actual-time")
            Label(
                selectedDistance(for: displayedDate),
                systemImage: "arrow.left.and.right"
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chart-distance")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart-time-distance")
    }

    private var displayedDate: Date {
        selectedDate ?? detail.summary.startDate
    }

    private func elapsedTime(for date: Date) -> String {
        MeasurementFormatterFactory.duration(
            min(
                detail.summary.duration,
                max(0, date.timeIntervalSince(detail.summary.startDate))
            )
        )
    }

    private func actualTime(for date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .standard,
                timeZone: detail.activityTimeZone
            )
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

private struct ChartValueOverlay: View {
    let plotFrame: Anchor<CGRect>?
    let xPosition: CGFloat?
    let yPosition: CGFloat?
    let text: String?

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame,
               let xPosition,
               let yPosition,
               let text {
                let frame = geometry[plotFrame]
                let horizontalInset = min(60, frame.width / 2)
                let x = min(
                    max(
                        frame.minX + xPosition,
                        frame.minX + horizontalInset
                    ),
                    frame.maxX - horizontalInset
                )
                let y = max(
                    frame.minY + 16,
                    frame.minY + yPosition - 24
                )

                Text(text)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .systemBackground))
                    )
                    .overlay {
                        Capsule()
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
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

            if let chartDomain = presentation.heartRateDomain {
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
                            x: .value(
                                "Selected time",
                                selectedSample.startDate
                            ),
                            y: .value("BPM", selectedSample.value)
                        )
                        .foregroundStyle(.red)
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXScale(domain: chartDomain.date)
                .chartYScale(domain: chartDomain.value)
                .chartYAxisLabel("beats/min")
                .chartOverlay { proxy in
                    ChartValueOverlay(
                        plotFrame: proxy.plotFrame,
                        xPosition: selectedSample.flatMap {
                            proxy.position(forX: $0.startDate)
                        },
                        yPosition: selectedSample.flatMap {
                            proxy.position(forY: $0.value)
                        },
                        text: selectedSample.map {
                            "\(Int($0.value.rounded())) bpm"
                        }
                    )
                }
                .frame(height: 320)
                .padding()
                .accessibilityIdentifier("heart-rate-chart")
            }

            HStack(spacing: 8) {
                CompactHeartRateMetric(
                    title: "Minimum",
                    value: "\(Int(detail.derived.minimumHeartRateBPM?.value.rounded() ?? 0)) bpm",
                    icon: "arrow.down",
                    accessibilityIdentifier: "heart-rate-minimum-metric"
                )
                CompactHeartRateMetric(
                    title: "Maximum",
                    value: "\(Int(detail.derived.maximumHeartRateBPM?.value.rounded() ?? 0)) bpm",
                    icon: "arrow.up",
                    accessibilityIdentifier: "heart-rate-maximum-metric"
                )
            }
            .padding(.horizontal)

            if let zones = detail.derived.heartRateZones {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Heart-Rate Zones").font(.headline)

                    ForEach(zones) { zone in
                        HStack(spacing: 6) {
                            Text("Zone \(zone.zone)")
                                .foregroundStyle(zoneColor(zone.zone))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: 50, alignment: .leading)
                            ProgressView(
                                value: zone.duration,
                                total: max(totalZoneDuration, 1)
                            )
                            .tint(zoneColor(zone.zone))
                            .frame(maxWidth: .infinity)
                            Text(zone.durationDescription)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 64, alignment: .trailing)
                            .accessibilityIdentifier(
                                "heart-rate-zone-duration-\(zone.zone)"
                            )
                            Text(zone.rangeDescription)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: 90, alignment: .trailing)
                                .accessibilityIdentifier(
                                    "heart-rate-zone-range-\(zone.zone)"
                                )
                        }
                        .font(.subheadline)
                    }
                    Text(
                        "Estimated time in each heart-rate zone. "
                            + "Personal analysis only; not medical guidance."
                    )
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

    private var totalZoneDuration: TimeInterval {
        detail.derived.heartRateZones?.reduce(0) { $0 + $1.duration } ?? 0
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: .blue
        case 2: .cyan
        case 3: .green
        case 4: .orange
        default: .pink
        }
    }
}

private struct CompactHeartRateMetric: View {
    let title: String
    let value: String
    let icon: String
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
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
                if let chartDomain = presentation.paceDomain {
                    Chart {
                        ForEach(presentation.pacePoints) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value(
                                    "Pace",
                                    displayPaceMinutes(
                                        secondsPerKilometer:
                                            point.paceSecondsPerKilometer
                                    )
                                ),
                                series: .value(
                                    "Continuous route segment",
                                    point.seriesID
                                )
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
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
                                        secondsPerKilometer:
                                            selectedPoint.paceSecondsPerKilometer
                                    )
                                )
                            )
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartXScale(domain: chartDomain.date)
                    .chartYScale(
                        domain: displayPaceDomain(chartDomain.value)
                    )
                    .chartYAxisLabel("min/\(units.paceUnitLabel)")
                    .chartOverlay { proxy in
                        ChartValueOverlay(
                            plotFrame: proxy.plotFrame,
                            xPosition: selectedPoint.flatMap {
                                proxy.position(forX: $0.timestamp)
                            },
                            yPosition: selectedPoint.flatMap {
                                proxy.position(
                                    forY: displayPaceMinutes(
                                        secondsPerKilometer:
                                            $0.paceSecondsPerKilometer
                                    )
                                )
                            },
                            text: selectedPoint.map {
                                selectedPace(
                                    secondsPerKilometer:
                                        $0.paceSecondsPerKilometer
                                )
                            }
                        )
                    }
                    .frame(height: 280)
                    .accessibilityIdentifier("pace-chart")
                }
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

    private func displayPaceMinutes(
        secondsPerKilometer: Double
    ) -> Double {
        let seconds = units == .metric
            ? secondsPerKilometer
            : secondsPerKilometer * 1.609_344
        return seconds / 60
    }

    private func displayPaceDomain(
        _ secondsPerKilometer: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        let lowerBound = displayPaceMinutes(
            secondsPerKilometer: secondsPerKilometer.lowerBound
        )
        let upperBound = displayPaceMinutes(
            secondsPerKilometer: secondsPerKilometer.upperBound
        )
        return lowerBound...upperBound
    }

    private func selectedPace(secondsPerKilometer: Double?) -> String {
        return MeasurementFormatterFactory.pace(
            secondsPerKilometer: secondsPerKilometer,
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

            if let chartDomain = presentation.elevationDomain {
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
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXScale(domain: chartDomain.date)
                .chartYScale(
                    domain: displayAltitudeDomain(chartDomain.value)
                )
                .chartYAxisLabel(units == .metric ? "meters" : "feet")
                .chartOverlay { proxy in
                    ChartValueOverlay(
                        plotFrame: proxy.plotFrame,
                        xPosition: selectedPoint.flatMap {
                            proxy.position(forX: $0.timestamp)
                        },
                        yPosition: selectedPoint.flatMap {
                            proxy.position(
                                forY: displayAltitude($0.altitudeMeters)
                            )
                        },
                        text: selectedPoint.map {
                            MeasurementFormatterFactory.elevation(
                                $0.altitudeMeters,
                                preference: units
                            )
                        }
                    )
                }
                .frame(height: 320)
                .padding()
                .accessibilityIdentifier("elevation-chart")
            }
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

    private func displayAltitudeDomain(
        _ meters: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        let lowerBound = displayAltitude(meters.lowerBound)
        let upperBound = displayAltitude(meters.upperBound)
        return lowerBound...upperBound
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
                        Text(
                            MeasurementFormatterFactory.splitDistance(
                                actualMeters: split.distanceMeters,
                                configuredDistanceMeters: configuredSplitDistance,
                                preference: units
                            )
                        )
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

    private var configuredSplitDistance: Double? {
        detail.metricSettings.splitMode == .distance
            ? detail.metricSettings.splitDistanceMeters
            : nil
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
