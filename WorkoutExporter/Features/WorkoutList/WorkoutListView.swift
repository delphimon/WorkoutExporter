import SwiftUI

struct WorkoutListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @State private var model = WorkoutListViewModel()
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var showBatchExport = false

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ContentUnavailableView {
                    Label("Loading Workouts", systemImage: "heart.text.square")
                } description: {
                    ProgressView()
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Workouts Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .overlay(alignment: .bottom) {
                    Button("Try Again") { Task { await model.load(using: environment.healthClient) } }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
            case .loaded:
                workoutContent
            }
        }
        .navigationTitle(environment.isUsingSyntheticData ? "Sample Workouts" : "Workouts")
        .searchable(text: $model.searchText, prompt: "Activity or source")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Filter", systemImage: "line.3.horizontal.decrease.circle") { showFilters = true }
                    .accessibilityIdentifier("workout-filter-button")
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("workout-settings-button")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(model.isSelecting ? "Done" : "Select") {
                    model.isSelecting.toggle()
                    if !model.isSelecting { model.selectedIDs.removeAll() }
                }
            }
            if model.isSelecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("Export \(model.selectedIDs.count) Selected", systemImage: "square.and.arrow.up") {
                        showBatchExport = true
                    }
                    .disabled(model.selectedIDs.isEmpty)
                }
            }
        }
        .refreshable { await model.load(using: environment.healthClient) }
        .task(id: environment.isUsingSyntheticData) { await model.load(using: environment.healthClient) }
        .sheet(isPresented: $showFilters) { WorkoutFilterView(model: model) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showBatchExport) {
            BatchExportView(workoutIDs: Array(model.selectedIDs))
        }
    }

    @ViewBuilder
    private var workoutContent: some View {
        if model.filteredWorkouts.isEmpty {
            ContentUnavailableView(
                "No Matching Workouts",
                systemImage: "figure.walk",
                description: Text("Change the search or filters, or review Health permissions.")
            )
        } else {
            List(model.filteredWorkouts) { workout in
                if model.isSelecting {
                    Button {
                        model.toggleSelection(workout.id)
                    } label: {
                        HStack {
                            Image(systemName: model.selectedIDs.contains(workout.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedIDs.contains(workout.id) ? Color.accentColor : .secondary)
                            WorkoutRow(workout: workout, units: settings.distanceUnits)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: workout) {
                        WorkoutRow(workout: workout, units: settings.distanceUnits)
                    }
                    .accessibilityIdentifier("workout-row-\(workout.id.uuidString)")
                }
                if workout.id == model.filteredWorkouts.last?.id, model.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await model.loadMore(using: environment.healthClient) }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("workout-list")
            .navigationDestination(for: WorkoutSummary.self) { workout in
                WorkoutDetailView(workout: workout)
            }
        }
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutSummary
    let units: DistanceUnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workout.activityName).font(.headline)
                Spacer()
                if workout.hasRoute {
                    Image(systemName: "map.fill").accessibilityLabel("GPS route available")
                }
                if workout.hasDetailedSamples {
                    Image(systemName: "waveform.path.ecg").accessibilityLabel("Detailed samples available")
                }
            }
            Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label(MeasurementFormatterFactory.duration(workout.duration), systemImage: "clock")
                Label(MeasurementFormatterFactory.distance(workout.totalDistanceMeters, preference: units), systemImage: "arrow.left.and.right")
                if let heartRate = workout.averageHeartRateBPM {
                    Label("\(Int(heartRate.rounded())) bpm", systemImage: "heart.fill")
                }
                if let energy = workout.activeEnergyKilocalories {
                    Label("\(Int(energy.rounded())) kcal", systemImage: "flame")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(workout.source.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutFilterView: View {
    @Bindable var model: WorkoutListViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(UserSettings.self) private var settings

    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $model.selectedActivity) {
                    ForEach(model.activityOptions, id: \.self) { Text($0) }
                }
                Picker("Source", selection: $model.selectedSource) {
                    ForEach(model.sourceOptions, id: \.self) { Text($0) }
                }
                Picker("Date", selection: $model.dateRange) {
                    ForEach(WorkoutListViewModel.DateRange.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(WorkoutListViewModel.SortOrder.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Toggle("Has GPS route", isOn: $model.routeOnly)
                Toggle("Has heart-rate data", isOn: $model.heartRateOnly)
                VStack(alignment: .leading) {
                    Text("Minimum duration: \(Int(model.minimumDurationMinutes)) minutes")
                    Slider(value: $model.minimumDurationMinutes, in: 0...180, step: 5)
                }
                VStack(alignment: .leading) {
                    Text(
                        "Minimum distance: "
                            + MeasurementFormatterFactory.distance(
                                model.minimumDistanceMeters,
                                preference: settings.distanceUnits
                            )
                    )
                    Slider(value: $model.minimumDistanceMeters, in: 0...50_000, step: 500)
                }
                Button("Reset Filters", role: .destructive) {
                    model.resetFilters()
                }
                .accessibilityIdentifier("reset-filters-button")
            }
            .navigationTitle("Filters")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .presentationDetents([.medium])
    }
}
