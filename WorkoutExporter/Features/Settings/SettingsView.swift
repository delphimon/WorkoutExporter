import SwiftUI

struct SettingsView: View {
    @Environment(UserSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacy = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Distance and pace", selection: $settings.distanceUnits) {
                        ForEach(DistanceUnitPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Metric calculation") {
                    VStack(alignment: .leading) {
                        Text("Moving threshold: \(MeasurementFormatterFactory.speed(settings.metricSettings.movingSpeedThresholdMetersPerSecond, preference: settings.distanceUnits))")
                        Slider(value: $settings.metricSettings.movingSpeedThresholdMetersPerSecond, in: 0.2...3, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Route gap: \(Int(settings.metricSettings.maximumRouteGap)) seconds")
                        Slider(value: $settings.metricSettings.maximumRouteGap, in: 5...120, step: 5)
                    }
                }
                Section("Export defaults") {
                    Toggle("Package as ZIP", isOn: $settings.packageAsZIP)
                    Toggle("Include raw samples", isOn: $settings.includeRawSamples)
                    Toggle("Include source/device metadata", isOn: $settings.includeSourceMetadata)
                    LabeledContent("Schema version", value: "1.0.0")
                }
                Section("Privacy") {
                    Button("How your data is handled") { showPrivacy = true }
                    Text("Heart-rate zones and derived metrics are for personal analysis, not medical guidance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #if DEBUG
                Section("Developer") {
                    Button(environment.isUsingSyntheticData ? "Use Live HealthKit" : "Use Synthetic Workouts") {
                        if environment.isUsingSyntheticData {
                            environment.useLiveData()
                        } else {
                            environment.useSyntheticData()
                        }
                        dismiss()
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { settings.persistBooleans(); dismiss() } }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
        }
    }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Health data is read and processed locally on this iPhone.")
                    Text("Exports are created only when you request them.")
                    Text("You choose where exports are sent using Apple's share sheet.")
                    Text("Workout Exporter does not transmit workout data to the developer.")
                }
                Section("Not included") {
                    Text("No analytics SDK, advertising SDK, remote account, automatic cloud upload, or background transmission.")
                }
            }
            .navigationTitle("Privacy")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
