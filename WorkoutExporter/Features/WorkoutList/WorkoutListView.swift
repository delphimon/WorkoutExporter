import SwiftUI

struct WorkoutListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @State private var model = WorkoutListViewModel()
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var showBatchExport = false
    @State private var workoutToEditLocationTag: WorkoutSummary?
    @State private var metadataError: String?

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
                Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    syncMetadata()
                    showFilters = true
                }
                    .accessibilityIdentifier("workout-filter-button")
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("workout-settings-button")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(model.isSelecting ? "Done" : "Select") {
                    model.isSelecting.toggle()
                    if !model.isSelecting { model.clearSelection() }
                }
            }
            if model.isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Export \(model.selectedIDs.count) Selected", systemImage: "square.and.arrow.up") {
                        showBatchExport = true
                    }
                    .disabled(model.selectedIDs.isEmpty)
                    .accessibilityIdentifier("export-selected-workouts-button")
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        Button("Select All", systemImage: "checkmark.circle") {
                            model.selectAllFiltered()
                        }
                        .disabled(model.filteredWorkouts.isEmpty)
                        Divider()
                        Button("Mark Selected Not Exported", systemImage: "arrow.uturn.backward.circle") {
                            clearExportedFlags(for: model.selectedIDs)
                        }
                        .disabled(
                            model.selectedIDs.isDisjoint(
                                with: environment.workoutMetadataStore.exportedWorkoutIDs
                            )
                        )
                        if model.selectedIDs.count == 1,
                           let workout = model.workouts.first(where: {
                               model.selectedIDs.contains($0.id)
                           }) {
                            Button("Edit Location Tag", systemImage: "mappin.and.ellipse") {
                                workoutToEditLocationTag = workout
                            }
                        }
                    }
                    .accessibilityIdentifier("selected-workout-actions-button")
                }
            }
        }
        .refreshable { await model.load(using: environment.healthClient) }
        .task(id: environment.isUsingSyntheticData) {
            syncMetadata()
            await model.load(using: environment.healthClient)
        }
        .onAppear {
            syncMetadata()
        }
        .onChange(of: environment.workoutMetadataStore.exportedWorkoutIDs) {
            model.exportedWorkoutIDs = $1
        }
        .onChange(of: environment.workoutMetadataStore.customLocationTags) {
            model.customLocationTags = $1
        }
        .sheet(isPresented: $showFilters) { WorkoutFilterView(model: model) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showBatchExport, onDismiss: syncMetadata) {
            BatchExportView(workoutIDs: Array(model.selectedIDs))
        }
        .sheet(
            item: $workoutToEditLocationTag,
            onDismiss: syncMetadata
        ) { workout in
            WorkoutLocationTagEditor(workout: workout)
        }
        .alert(
            "Workout Metadata",
            isPresented: Binding(
                get: { metadataError != nil },
                set: { if !$0 { metadataError = nil } }
            )
        ) {
            Button("OK") { metadataError = nil }
        } message: {
            Text(metadataError ?? "")
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
                            WorkoutRow(
                                workout: workout,
                                units: settings.distanceUnits,
                                customLocationTag: environment.workoutMetadataStore.customLocationTag(
                                    for: workout.id
                                ),
                                isExported: environment.workoutMetadataStore.isExported(
                                    workout.id
                                )
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout-row-\(workout.id.uuidString)")
                } else {
                    NavigationLink(value: workout) {
                        WorkoutRow(
                            workout: workout,
                            units: settings.distanceUnits,
                            customLocationTag: environment.workoutMetadataStore.customLocationTag(
                                for: workout.id
                            ),
                            isExported: environment.workoutMetadataStore.isExported(
                                workout.id
                            )
                        )
                    }
                    .accessibilityIdentifier("workout-row-\(workout.id.uuidString)")
                    .swipeActions(edge: .trailing) {
                        Button("Edit Location", systemImage: "mappin.and.ellipse") {
                            workoutToEditLocationTag = workout
                        }
                        if environment.workoutMetadataStore.isExported(workout.id) {
                            Button("Not Exported", systemImage: "arrow.uturn.backward.circle") {
                                clearExportedFlags(for: [workout.id])
                            }
                            .tint(.orange)
                        }
                    }
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

    private func syncMetadata() {
        model.exportedWorkoutIDs = environment.workoutMetadataStore.exportedWorkoutIDs
        model.customLocationTags = environment.workoutMetadataStore.customLocationTags
        if let persistenceError = environment.workoutMetadataStore.lastPersistenceError {
            metadataError = "Saved workout status could not be loaded: \(persistenceError)"
        }
    }

    private func clearExportedFlags(for workoutIDs: some Sequence<UUID>) {
        do {
            try environment.workoutMetadataStore.clearExportedFlag(for: workoutIDs)
            syncMetadata()
        } catch {
            metadataError = error.localizedDescription
        }
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutSummary
    let units: DistanceUnitPreference
    let customLocationTag: String?
    let isExported: Bool
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
                    if isExported {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Exported")
                            .accessibilityIdentifier(
                                "workout-exported-\(workout.id.uuidString)"
                            )
                    }
                    if workout.hasDetailedSamples {
                        Image(systemName: "waveform.path.ecg")
                            .accessibilityLabel("Detailed samples available")
                    }
                }
                if let customLocationTag {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customLocationTag)
                            .font(.subheadline.weight(.semibold))
                        Text("Custom location")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if let placeLabel {
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
                Toggle("Not yet exported", isOn: $model.unexportedOnly)
                    .accessibilityIdentifier("unexported-only-filter")
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

private struct WorkoutLocationTagEditor: View {
    let workout: WorkoutSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var locationTag = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity Location") {
                    TextField("Location tag", text: $locationTag)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("workout-location-tag-field")
                    Text("\(locationTag.count) of 120 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Recorded activity", value: workout.activityName)
                    Text(
                        "This replaces only the automatic Maps location shown under the "
                            + "activity type. It does not change the activity type, exported "
                            + "filenames, or workout data."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if environment.workoutMetadataStore.customLocationTag(for: workout.id) != nil {
                    Section {
                        Button("Use Automatic Location", role: .destructive) {
                            save(nil)
                        }
                        .accessibilityIdentifier("clear-workout-location-tag-button")
                    }
                }
            }
            .navigationTitle("Edit Location Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(locationTag) }
                        .disabled(
                            locationTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("save-workout-location-tag-button")
                }
            }
            .onAppear {
                locationTag = environment.workoutMetadataStore.customLocationTag(
                    for: workout.id
                ) ?? ""
            }
            .onChange(of: locationTag) {
                if $1.count > 120 {
                    locationTag = String($1.prefix(120))
                }
            }
            .alert(
                "Unable to Save Location",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
    }

    private func save(_ value: String?) {
        do {
            try environment.workoutMetadataStore.setCustomLocationTag(
                value,
                for: workout.id
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
