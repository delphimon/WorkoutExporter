import SwiftUI

struct WorkoutStatsView: View {
    let workouts: [WorkoutSummary]
    let isLoading: Bool
    let hasMore: Bool
    @Environment(UserSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isLoading { Section { ProgressView("Loading all filtered workouts…") } }
                ForEach(groupedStats) { group in
                    Section {
                        LabeledContent("Activities", value: group.count.formatted())
                        LabeledContent(
                            "Total distance",
                            value: MeasurementFormatterFactory.distance(
                                group.totalDistanceMeters, preference: settings.distanceUnits))
                        LabeledContent("Total time", value: MeasurementFormatterFactory.duration(group.totalDuration))
                        LabeledContent(
                            "Total elevation gain",
                            value: MeasurementFormatterFactory.elevation(
                                group.totalElevationGainMeters, preference: settings.distanceUnits))
                    } header: {
                        Label(
                            group.activityName,
                            systemImage: WorkoutActivityPresentation.symbolName(for: group.activityName))
                    }
                }
                Section {
                    Text(
                        "Totals use the native HealthKit workout summaries for the current "
                            + "filters. A missing distance or elevation value does not contribute "
                            + "to that total; recorded values are never smoothed or replaced."
                    ).font(.footnote).foregroundStyle(.secondary)
                    if hasMore {
                        Text("More workouts remain to be loaded, so these totals are not final.").font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }.overlay {
                if groupedStats.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "No Filtered Stats", systemImage: "chart.bar.xaxis",
                        description: Text("No workouts match the current filters."))
                }
            }.navigationTitle("Filtered Stats").toolbar { Button("Done") { dismiss() } }
        }
    }

    private var groupedStats: [WorkoutActivityStats] { WorkoutStatsCalculator.group(workouts) }
}

enum WorkoutStatsCalculator {
    static func group(_ workouts: [WorkoutSummary]) -> [WorkoutActivityStats] {
        Dictionary(grouping: workouts, by: \.activityName).map { activityName, workouts in
            WorkoutActivityStats(
                activityName: activityName, count: workouts.count,
                totalDistanceMeters: sumIfPresent(workouts.compactMap(\.totalDistanceMeters)),
                totalDuration: workouts.map(\.duration).reduce(0, +),
                totalElevationGainMeters: sumIfPresent(workouts.compactMap(\.elevationGainMeters)))
        }.sorted { $0.activityName < $1.activityName }
    }

    private static func sumIfPresent(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) }
}

struct WorkoutActivityStats: Identifiable, Equatable {
    var id: String { activityName }
    var activityName: String
    var count: Int
    var totalDistanceMeters: Double?
    var totalDuration: TimeInterval
    var totalElevationGainMeters: Double?
}
