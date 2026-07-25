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
    @State private var selectedDate: Date?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading workout details…")
            case .failed(let message):
                ContentUnavailableView("Detail Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded(let detail):
                detailContent(detail)
            }
        }
        .navigationTitle(workout.activityName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
                .accessibilityIdentifier("workout-export-button")
        }
        .sheet(isPresented: $showExport) {
            if case .loaded(let detail) = model.state {
                ExportView(requests: [.loaded(detail)])
            }
        }
        .task {
            await model.load(id: workout.id, client: environment.healthClient, settings: settings.metricSettings)
        }
    }

    private func detailContent(_ detail: WorkoutDetail) -> some View {
        VStack(spacing: 0) {
            Picker("Detail section", selection: $selectedSection) {
                ForEach(DetailSection.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .accessibilityIdentifier("detail-section-picker")

            ScrollView {
                switch selectedSection {
                case .summary: SummarySection(detail: detail, units: settings.distanceUnits)
                case .map: RouteMapSection(detail: detail, selectedDate: $selectedDate)
                case .heartRate: HeartRateSection(detail: detail, selectedDate: $selectedDate)
                case .pace: PaceSection(detail: detail, units: settings.distanceUnits, selectedDate: $selectedDate)
                case .elevation: ElevationSection(detail: detail, units: settings.distanceUnits, selectedDate: $selectedDate)
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
    let detail: WorkoutDetail
    let units: DistanceUnitPreference

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCard("Duration", MeasurementFormatterFactory.duration(detail.summary.duration), "clock")
            MetricCard("Workout Distance", MeasurementFormatterFactory.distance(detail.summary.totalDistanceMeters, preference: units), "figure.run")
            MetricCard("GPS-Derived Distance", MeasurementFormatterFactory.distance(detail.derived.routeDistanceMeters?.value, preference: units), "location")
            MetricCard("Moving Time", MeasurementFormatterFactory.duration(detail.derived.eventAwareMovingTime?.value ?? 0), "pause.circle")
            MetricCard("Average Heart Rate", detail.derived.averageHeartRateBPM.map { "\(Int($0.value.rounded())) bpm" } ?? "—", "heart")
            MetricCard("Workout Elevation Gain", MeasurementFormatterFactory.elevation(detail.summary.elevationGainMeters, preference: units), "mountain.2")
        }
        .padding()

        if !detail.warnings.isEmpty {
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

private struct RouteMapSection: View {
    let detail: WorkoutDetail
    @Binding var selectedDate: Date?

    var body: some View {
        if detail.routePoints.isEmpty {
            ContentUnavailableView("No GPS Route", systemImage: "map", description: Text("Other workout details remain available."))
                .frame(minHeight: 400)
        } else {
            Map {
                ForEach(detail.routes.sorted(by: { $0.key.uuidString < $1.key.uuidString }), id: \.key) { _, points in
                    MapPolyline(coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(.blue, lineWidth: 4)
                }
                if let first = detail.routePoints.first {
                    Marker("Start", systemImage: "flag.fill", coordinate: .init(latitude: first.latitude, longitude: first.longitude))
                        .tint(.green)
                }
                if let last = detail.routePoints.last {
                    Marker("Finish", systemImage: "flag.checkered", coordinate: .init(latitude: last.latitude, longitude: last.longitude))
                        .tint(.red)
                }
                if let selected = selectedPoint {
                    Marker(
                        "Selected \(selected.timestamp.formatted(date: .omitted, time: .standard))",
                        systemImage: "scope",
                        coordinate: .init(latitude: selected.latitude, longitude: selected.longitude)
                    )
                    .tint(.orange)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(minHeight: 500)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private var selectedPoint: RoutePoint? {
        guard let selectedDate else { return nil }
        return detail.routePoints.min {
            abs($0.timestamp.timeIntervalSince(selectedDate))
                < abs($1.timestamp.timeIntervalSince(selectedDate))
        }
    }
}

private struct HeartRateSection: View {
    let detail: WorkoutDetail
    @Binding var selectedDate: Date?

    var body: some View {
        if detail.heartRateSamples.isEmpty {
            ContentUnavailableView("No Heart-Rate Data", systemImage: "heart.slash", description: Text("The route and other workout data are still available."))
                .frame(minHeight: 400)
        } else {
            Chart(displaySamples) { sample in
                LineMark(x: .value("Time", sample.startDate), y: .value("BPM", sample.value))
                    .foregroundStyle(.red)
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
        }
    }

    private var displaySamples: [WorkoutSample] {
        downsample(detail.heartRateSamples, limit: 1_200)
    }
}

private struct PaceSection: View {
    let detail: WorkoutDetail
    let units: DistanceUnitPreference
    @Binding var selectedDate: Date?

    var body: some View {
        VStack(spacing: 12) {
            if !displayPoints.isEmpty {
                Chart(displayPoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Speed", displaySpeed(point.speedMetersPerSecond))
                    )
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxisLabel(units == .metric ? "km/h" : "mph")
                .frame(height: 280)
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

    private var displayPoints: [RoutePoint] {
        downsample(
            detail.routePoints.filter { $0.speedMetersPerSecond != nil },
            limit: 1_200
        )
    }

    private func displaySpeed(_ metersPerSecond: Double?) -> Double {
        guard let metersPerSecond else { return 0 }
        return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
            .converted(to: units.speedUnit)
            .value
    }
}

private struct ElevationSection: View {
    let detail: WorkoutDetail
    let units: DistanceUnitPreference
    @Binding var selectedDate: Date?

    var body: some View {
        if detail.routePoints.isEmpty {
            ContentUnavailableView("No Elevation Data", systemImage: "mountain.2")
        } else {
            Chart(displayPoints) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Altitude", displayAltitude(point.altitudeMeters))
                )
                    .foregroundStyle(.green.opacity(0.5))
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
        }
    }

    private var displayPoints: [RoutePoint] {
        downsample(detail.routePoints, limit: 1_200)
    }

    private func displayAltitude(_ meters: Double) -> Double {
        Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: units.elevationUnit)
            .value
    }
}

private func downsample<Element>(_ values: [Element], limit: Int) -> [Element] {
    guard values.count > limit, limit > 1 else { return values }
    let stride = Double(values.count - 1) / Double(limit - 1)
    return (0..<limit).map { values[min(values.count - 1, Int((Double($0) * stride).rounded()))] }
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
