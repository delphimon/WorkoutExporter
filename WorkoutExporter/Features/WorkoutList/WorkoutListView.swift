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
                    Button("Load More Workouts") {
                        Task { await model.loadMore(using: environment.healthClient) }
                    }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("load-more-workouts-button")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("workout-list")
            .safeAreaInset(edge: .bottom) {
                if let message = model.paginationError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .navigationDestination(for: WorkoutSummary.self) { workout in
                WorkoutDetailView(workout: workout)
            }
        }
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutSummary
    let units: DistanceUnitPreference
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if workout.hasRoute {
                routeThumbnail
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        workout.activityName,
                        systemImage: WorkoutActivityPresentation.symbolName(
                            for: workout.activityName
                        )
                    )
                    .font(.headline)
                    .accessibilityIdentifier("workout-type-\(workout.id.uuidString)")
                    Spacer()
                    if workout.hasDetailedSamples {
                        Image(systemName: "waveform.path.ecg")
                            .accessibilityLabel("Detailed samples available")
                    }
                }
                if let placeLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(placeLabel.name)
                            .font(.subheadline.weight(.semibold))
                        Text(placeDescription(placeLabel))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("workout-place-\(workout.id.uuidString)")
                }
                Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(rowMetrics, id: \.icon) { metric in
                        Label(metric.value, systemImage: metric.icon)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(workout.source.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .task(id: workout.id) {
            environment.routePresentationStore.enqueue(
                workout: workout,
                client: environment.healthClient
            )
        }
    }

    @ViewBuilder
    private var routeThumbnail: some View {
        Group {
            switch environment.routePresentationStore.state(for: workout.id) {
            case .loaded(let presentation):
                if let image = presentation.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    mapPlaceholder(showProgress: false)
                }
            case .loading:
                mapPlaceholder(showProgress: true)
            case .unavailable, nil:
                mapPlaceholder(showProgress: false)
            }
        }
        .frame(width: 76, height: 64)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityLabel("Workout route map preview")
        .accessibilityIdentifier("workout-map-thumbnail-\(workout.id.uuidString)")
    }

    private func mapPlaceholder(showProgress: Bool) -> some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if showProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeLabel: WorkoutPlaceLabel? {
        guard case .loaded(let presentation) =
                environment.routePresentationStore.state(for: workout.id) else {
            return nil
        }
        return presentation.placeLabel
    }

    private func placeDescription(_ label: WorkoutPlaceLabel) -> String {
        switch label.kind {
        case .hike: "Suggested hike name · \(label.source)"
        case .neighborhood: "Neighborhood · \(label.source)"
        }
    }

    private var rowMetrics: [RowMetric] {
        var values = [
            RowMetric(
                icon: "clock",
                value: MeasurementFormatterFactory.duration(workout.duration)
            ),
            RowMetric(
                icon: "arrow.left.and.right",
                value: MeasurementFormatterFactory.distance(
                    workout.totalDistanceMeters,
                    preference: units
                )
            )
        ]
        if let heartRate = workout.averageHeartRateBPM {
            values.append(RowMetric(
                icon: "heart.fill",
                value: "\(Int(heartRate.rounded())) bpm"
            ))
        }
        if let energy = workout.activeEnergyKilocalories {
            values.append(RowMetric(
                icon: "flame",
                value: "\(Int(energy.rounded())) kcal"
            ))
        }
        return values
    }

    private struct RowMetric {
        var icon: String
        var value: String
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
