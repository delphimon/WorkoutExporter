import SwiftUI

struct ExportView: View {
    let details: [WorkoutDetail]
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: ExportProgress?

    var body: some View {
        NavigationStack {
            Form {
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
                Section("Calculations") {
                    Picker("Moving time", selection: $options.movingTimeMethod) {
                        ForEach(MovingTimeMethod.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Presentation units", selection: $options.units) {
                        ForEach(DistanceUnitPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                if isExporting {
                    Section {
                        ProgressView(
                            exportProgress?.message
                                ?? "Preparing \(details.count) workout\(details.count == 1 ? "" : "s")…"
                        )
                        Button("Cancel", role: .destructive) { exportTask?.cancel() }
                    }
                }
                if let outputURL {
                    Section("Ready") {
                        ShareLink(item: outputURL) {
                            Label("Share \(outputURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        Text(fileSize(outputURL)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createExport() }
                        .disabled(isExporting || options.formats.isEmpty)
                }
            }
            .onAppear {
                options.formats = settings.defaultFormats
                options.units = settings.distanceUnits
                options.includeRawSamples = settings.includeRawSamples
                options.includeSourceAndDevice = settings.includeSourceMetadata
                options.packageAsZIP = settings.packageAsZIP
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
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                outputURL = try await environment.packageBuilder.buildPackage(
                    for: details,
                    options: options,
                    to: directory
                ) { update in
                    await MainActor.run {
                        exportProgress = update
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct BatchExportView: View {
    let workoutIDs: [UUID]
    @Environment(AppEnvironment.self) private var environment
    @Environment(UserSettings.self) private var settings
    @State private var details: [WorkoutDetail] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !details.isEmpty {
                ExportView(details: details)
            } else if let errorMessage {
                ContentUnavailableView("Could Not Prepare Export", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Loading selected workouts…")
            }
        }
        .task {
            do {
                var loaded: [WorkoutDetail] = []
                for id in workoutIDs {
                    loaded.append(try await environment.healthClient.fetchWorkoutDetail(id: id, settings: settings.metricSettings))
                }
                details = loaded
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
