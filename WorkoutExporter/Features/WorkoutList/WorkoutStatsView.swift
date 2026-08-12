import SwiftUI

struct WorkoutStatsView: View {
    let workouts: [WorkoutSummary]
    let isLoading: Bool
    let hasMore: Bool
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var outputURL: URL?
    @State private var existingExportURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading { Section { ProgressView("Loading all filtered workouts…") } }
                if !workouts.isEmpty {
                    Section("Activity List Export") {
                        if let shareURL = outputURL ?? existingExportURL {
                            ShareLink(item: shareURL) {
                                Label(
                                    "Share \(shareURL.lastPathComponent)",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .accessibilityIdentifier("share-filtered-stats-export-button")
                        }
                        Button {
                            createFilteredExport()
                        } label: {
                            Label(
                                outputURL == nil && existingExportURL == nil
                                    ? "Create Activity List CSV"
                                    : "Create Fresh Activity List CSV",
                                systemImage: "tablecells"
                            )
                        }
                        .disabled(isLoading || hasMore)
                        .accessibilityIdentifier("create-filtered-stats-export-button")
                        Text(
                            "Exports one row for every filtered activity with stable workout IDs, dates, recorded totals, source, location tag, and explicit \(settings.distanceUnits.label.lowercased()) units. It uses the loaded list and does not refetch samples or routes."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        if isLoading || hasMore {
                            Text("Export becomes available after all workouts matching the filters finish loading.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if let exportError {
                            Label(exportError, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(groupedStats) { group in
                    Section {
                        LabeledContent("Activities", value: group.count.formatted())
                        LabeledContent("Total time", value: MeasurementFormatterFactory.duration(group.totalDuration))
                        if let distance = group.totalDistanceMeters {
                            LabeledContent(
                                "Total distance",
                                value: MeasurementFormatterFactory.distance(
                                    distance, preference: settings.distanceUnits))
                        }
                        if let elevation = group.totalElevationGainMeters {
                            LabeledContent(
                                "Total elevation gain",
                                value: MeasurementFormatterFactory.elevation(
                                    elevation, preference: settings.distanceUnits))
                        }
                        if let energy = group.totalActiveEnergyKilocalories {
                            LabeledContent(
                                "Total active energy",
                                value: "\(Int(energy.rounded()).formatted()) kcal"
                            )
                        }
                        if let heartRate = group.durationWeightedAverageHeartRateBPM {
                            LabeledContent(
                                "Time-weighted average heart rate",
                                value: "\(Int(heartRate.rounded())) bpm"
                            )
                        }
                    } header: {
                        Label(
                            group.activityName,
                            systemImage: WorkoutActivityCatalog.symbolName(
                                for: group.activityIdentifier,
                                fallbackName: group.activityName
                            ))
                    }
                }
                Section {
                    Text(
                        "Totals use the native HealthKit workout summaries for the current "
                            + "filters. Distance, elevation, active energy, and heart rate appear "
                            + "only when HealthKit recorded them. Missing values do not contribute; "
                            + "recorded values are never smoothed or replaced."
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
            }
            .navigationTitle("Filtered Stats")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { refreshExistingExport() }
            .onChange(of: workoutIDs) {
                outputURL = nil
                refreshExistingExport()
            }
            .onChange(of: settings.distanceUnits) {
                outputURL = nil
                refreshExistingExport()
            }
        }
    }

    private var groupedStats: [WorkoutActivityStats] { WorkoutStatsCalculator.group(workouts) }

    private var workoutIDs: [UUID] { workouts.map(\.id) }

    private var cacheKey: String {
        "filtered-summary|schema=\(ExportSchema.version)|units=\(settings.distanceUnits.rawValue)"
    }

    private func createFilteredExport() {
        exportError = nil
        do {
            let directory = environment.exportDirectory
            try ExportUtilities.createProtectedDirectory(at: directory)
            let records = workouts.map { workout in
                WorkoutSummaryExportRecord(
                    summary: workout,
                    locationTag: environment.workoutMetadataStore
                        .customLocationTag(for: workout.id),
                    wasExported: environment.workoutMetadataStore.isExported(workout.id)
                )
            }
            let name = "filtered-workouts-\(ExportUtilities.date(Date()).prefix(10))-\(records.count).csv"
            let url = directory.appending(path: name)
            try ExportUtilities.writeProtected(
                WorkoutSummaryCSVExporter.data(
                    records: records,
                    unitScheme: settings.distanceUnits
                ),
                to: url
            )
            try environment.workoutMetadataStore.recordExport(
                workoutIDs: workoutIDs,
                fileURL: url,
                cacheKey: cacheKey
            )
            outputURL = url
            refreshExistingExport()
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func refreshExistingExport() {
        existingExportURL = environment.workoutMetadataStore.cachedExport(
            for: workoutIDs,
            cacheKey: cacheKey
        )?.url
    }
}

enum WorkoutStatsCalculator {
    static func group(_ workouts: [WorkoutSummary]) -> [WorkoutActivityStats] {
        Dictionary(grouping: workouts, by: \.activityIdentifier).map { identifier, workouts in
            let fallbackName = workouts.first?.activityName
            return WorkoutActivityStats(
                activityIdentifier: identifier,
                activityName: WorkoutActivityCatalog.name(
                    for: identifier,
                    fallbackName: fallbackName
                ),
                count: workouts.count,
                totalDistanceMeters: sumIfPresent(workouts.compactMap(\.totalDistanceMeters)),
                totalDuration: workouts.map(\.duration).reduce(0, +),
                totalElevationGainMeters: sumIfPresent(workouts.compactMap(\.elevationGainMeters)),
                totalActiveEnergyKilocalories: sumIfPresent(
                    workouts.compactMap(\.activeEnergyKilocalories)
                ),
                durationWeightedAverageHeartRateBPM: durationWeightedHeartRate(workouts)
            )
        }.sorted { $0.activityName < $1.activityName }
    }

    private static func sumIfPresent(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) }

    private static func durationWeightedHeartRate(_ workouts: [WorkoutSummary]) -> Double? {
        let recorded = workouts.compactMap { workout -> (Double, TimeInterval)? in
            guard let heartRate = workout.averageHeartRateBPM,
                  heartRate.isFinite,
                  workout.duration.isFinite,
                  workout.duration > 0 else { return nil }
            return (heartRate, workout.duration)
        }
        let duration = recorded.reduce(0) { $0 + $1.1 }
        guard duration > 0 else { return nil }
        return recorded.reduce(0) { $0 + ($1.0 * $1.1) } / duration
    }
}

struct WorkoutActivityStats: Identifiable, Equatable {
    var id: UInt { activityIdentifier }
    var activityIdentifier: UInt
    var activityName: String
    var count: Int
    var totalDistanceMeters: Double?
    var totalDuration: TimeInterval
    var totalElevationGainMeters: Double?
    var totalActiveEnergyKilocalories: Double?
    var durationWeightedAverageHeartRateBPM: Double?
}
