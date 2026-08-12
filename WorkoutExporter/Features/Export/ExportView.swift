import SwiftUI

struct ExportView: View {
    let requests: [WorkoutExportRequest]
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var preset = ExportPreset.basic
    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: ExportProgress?
    @State private var existingExport: CachedWorkoutExport?
    @State private var existingExportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let existingExport, let existingExportURL, outputURL == nil {
                        Section("Existing Export") {
                            ShareLink(item: existingExportURL) {
                                Label(
                                    "Share \(existingExportURL.lastPathComponent)",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .accessibilityIdentifier("share-existing-export-button")
                            Text(
                                "Created "
                                    + existingExport.createdAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                    + ". This file matches the current export choices. Choose Create to build a fresh copy."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .id("export-share-section")
                    }
                    if let outputURL {
                        Section("Ready to Share") {
                            ShareLink(item: outputURL) {
                                Label(
                                    "Share \(outputURL.lastPathComponent)",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            Text(fileSize(outputURL))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("export-share-section")
                    }
                    Section("Export Type") {
                        Picker("Export type", selection: $preset) {
                            ForEach(ExportPreset.allCases) { choice in
                                Text(choice.title)
                                    .tag(choice)
                                    .accessibilityIdentifier("export-preset-\(choice.rawValue)")
                            }
                        }
                        .pickerStyle(.inline)
                        Text(preset.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if preset == .custom {
                        Section("Formats") {
                            ForEach(ExportFormat.allCases) { format in
                                Toggle(format.displayName, isOn: binding(for: format))
                            }
                            Toggle("Package as ZIP", isOn: $options.packageAsZIP)
                        }
                        Section("Data") {
                            Toggle("Raw samples", isOn: $options.includeRawSamples)
                            Toggle("Derived metrics", isOn: $options.includeDerivedMetrics)
                            Toggle("Heart rate", isOn: $options.includeHeartRate)
                            Toggle("GPS route", isOn: $options.includeRoute)
                            Toggle("Source and device metadata", isOn: $options.includeSourceAndDevice)
                        }
                    } else {
                        Section("Includes") {
                            if preset == .basic {
                                Label("One row per workout", systemImage: "tablecells")
                                Label(
                                    "Stable workout ID, dates, totals, source, and location tag",
                                    systemImage: "checkmark.circle"
                                )
                                Label(
                                    "\(settings.distanceUnits.label) distance, speed, and elevation",
                                    systemImage: "ruler"
                                )
                            } else {
                                Label(
                                    "Heart rate, biometrics, samples, and provenance in JSON",
                                    systemImage: "waveform.path.ecg"
                                )
                                Label("GPX track when GPS data is available", systemImage: "map")
                                Label("Canonical SI units with each value", systemImage: "ruler")
                            }
                        }
                    }
                    Section {
                        Text(
                            preset == .basic
                                ? "Displayed-unit values are converted directly from recorded workout totals. Missing values stay blank."
                                : "Detailed measurements retain their canonical HealthKit or SI units. The app does not smooth, replace, or invent workout values."
                        )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if isExporting {
                        Section {
                            ProgressView(
                                exportProgress?.message
                                    ?? "Preparing \(requests.count) workout\(requests.count == 1 ? "" : "s")…"
                            )
                            Button("Cancel", role: .destructive) { exportTask?.cancel() }
                        }
                    }
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityIdentifier("export-form")
                .onChange(of: outputURL) {
                    guard $1 != nil else { return }
                    withAnimation {
                        proxy.scrollTo("export-share-section", anchor: .top)
                    }
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createExport() }
                        .disabled(isExporting || options.formats.isEmpty)
                        .accessibilityIdentifier("create-export-button")
                }
            }
            .onAppear {
                preset = settings.defaultExportPreset
                applyOptions(for: preset)
                refreshExistingExport()
            }
            .onChange(of: preset) {
                applyOptions(for: $1)
            }
            .onChange(of: options) {
                outputURL = nil
                refreshExistingExport()
            }
            .onDisappear {
                exportTask?.cancel()
            }
        }
    }

    private func binding(for format: ExportFormat) -> Binding<Bool> {
        Binding(
            get: { options.formats.contains(format) },
            set: { isOn in
                if isOn { options.formats.insert(format) } else { options.formats.remove(format) }
            }
        )
    }

    private func createExport() {
        isExporting = true
        errorMessage = nil
        outputURL = nil
        exportProgress = nil
        exportTask = Task {
            defer {
                isExporting = false
                exportProgress = nil
            }
            do {
                let directory = environment.exportDirectory
                try ExportUtilities.createProtectedDirectory(at: directory)
                let result = try await environment.packageBuilder.buildPackageResult(
                    for: requests,
                    options: options,
                    to: directory
                ) { update in
                    await MainActor.run {
                        exportProgress = update
                    }
                }
                outputURL = result.url
                if let outputURL {
                    do {
                        try environment.workoutMetadataStore.recordExport(
                            workoutIDs: result.exportedWorkoutIDs,
                            fileURL: outputURL,
                            cachePackage: result.exportedWorkoutIDs
                                == Set(requests.map(\.id)),
                            cacheKey: options.cacheKey
                        )
                        refreshExistingExport()
                    } catch {
                        errorMessage = "Export created, but its history could not be saved: "
                            + error.localizedDescription
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshExistingExport() {
        let cached = environment.workoutMetadataStore.cachedExport(
            for: requests.map(\.id),
            cacheKey: options.cacheKey
        )
        existingExport = cached?.record
        existingExportURL = cached?.url
    }

    private func applyOptions(for preset: ExportPreset) {
        switch preset {
        case .basic:
            options = .basic(
                unitScheme: settings.distanceUnits,
                filenameFormat: settings.filenameFormat
            )
        case .detailed:
            options = .detailed(
                unitScheme: settings.distanceUnits,
                filenameFormat: settings.filenameFormat
            )
        case .custom:
            options = ExportOptions(
                formats: settings.defaultFormats,
                includeRawSamples: settings.includeRawSamples,
                includeDerivedMetrics: true,
                includeHeartRate: true,
                includeRoute: true,
                includeSourceAndDevice: settings.includeSourceMetadata,
                filenameFormat: settings.filenameFormat,
                packageAsZIP: settings.packageAsZIP,
                unitScheme: settings.distanceUnits
            )
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct BatchExportView: View {
    let workouts: [WorkoutSummary]
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings

    var body: some View {
        ExportView(requests: exportRequests)
    }

    private var exportRequests: [WorkoutExportRequest] {
        let client = environment.healthClient
        let metricSettings = settings.metricSettings
        return workouts.map { workout in
            let id = workout.id
            return WorkoutExportRequest(
                id: id,
                summary: workout,
                locationTag: environment.workoutMetadataStore.customLocationTag(for: id),
                wasExported: environment.workoutMetadataStore.isExported(id)
            ) {
                try await client.fetchWorkoutDetail(id: id, settings: metricSettings)
            }
        }
    }
}
