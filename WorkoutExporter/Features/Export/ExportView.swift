import SwiftUI

struct ExportView: View {
    let requests: [WorkoutExportRequest]
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
                Section {
                    Text("Exported measurements retain their canonical HealthKit or SI units. The app does not convert or replace workout values.")
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
                        .accessibilityIdentifier("create-export-button")
                }
            }
            .onAppear {
                options.formats = settings.defaultFormats
                options.filenameFormat = settings.filenameFormat
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
                try ExportUtilities.createProtectedDirectory(at: directory)
                outputURL = try await environment.packageBuilder.buildPackage(
                    for: requests,
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

    var body: some View {
        ExportView(requests: exportRequests)
    }

    private var exportRequests: [WorkoutExportRequest] {
        let client = environment.healthClient
        let metricSettings = settings.metricSettings
        return workoutIDs.map { id in
            WorkoutExportRequest(id: id) {
                try await client.fetchWorkoutDetail(id: id, settings: metricSettings)
            }
        }
    }
}
