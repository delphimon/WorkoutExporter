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
                    Picker("Distance, pace, and elevation", selection: $settings.distanceUnits) {
                        ForEach(DistanceUnitPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Metric calculation") {
                    VStack(alignment: .leading) {
                        Text("Moving threshold: \(MeasurementFormatterFactory.speed(settings.metricSettings.movingSpeedThresholdMetersPerSecond, preference: settings.distanceUnits))")
                        Slider(value: $settings.metricSettings.movingSpeedThresholdMetersPerSecond, in: 0.2...3, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Minimum moving interval: \(Int(settings.metricSettings.minimumMovingDuration)) seconds")
                        Slider(value: $settings.metricSettings.minimumMovingDuration, in: 1...30, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Stopped interval: \(Int(settings.metricSettings.minimumStoppedDuration)) seconds")
                        Slider(value: $settings.metricSettings.minimumStoppedDuration, in: 1...30, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Route gap: \(Int(settings.metricSettings.maximumRouteGap)) seconds")
                        Slider(value: $settings.metricSettings.maximumRouteGap, in: 5...120, step: 5)
                    }
                }
                Section("Splits") {
                    Picker("Split type", selection: $settings.metricSettings.splitMode) {
                        Text("Distance").tag(SplitMode.distance)
                        Text("Elapsed time").tag(SplitMode.elapsedTime)
                    }
                    if settings.metricSettings.splitMode == .distance {
                        VStack(alignment: .leading) {
                            Text(
                                "Length: " + MeasurementFormatterFactory.distance(
                                    settings.metricSettings.splitDistanceMeters,
                                    preference: settings.distanceUnits
                                )
                            )
                            Slider(
                                value: $settings.metricSettings.splitDistanceMeters,
                                in: 400...5_000,
                                step: 100
                            )
                        }
                    } else {
                        Stepper(
                            "Interval: \(Int(settings.metricSettings.splitElapsedTime / 60)) minutes",
                            value: $settings.metricSettings.splitElapsedTime,
                            in: 60...3_600,
                            step: 60
                        )
                    }
                }
                Section("Heart-rate zones") {
                    Picker("Method", selection: $settings.metricSettings.heartRateZones.method) {
                        Text("Manual boundaries").tag(HeartRateZoneMethod.manual)
                        Text("% maximum HR").tag(HeartRateZoneMethod.percentMaximum)
                        Text("% heart-rate reserve").tag(HeartRateZoneMethod.heartRateReserve)
                    }
                    if settings.metricSettings.heartRateZones.method != .manual {
                        Stepper(
                            "Maximum: \(Int(settings.metricSettings.heartRateZones.maximumHeartRateBPM)) bpm",
                            value: $settings.metricSettings.heartRateZones.maximumHeartRateBPM,
                            in: 100...240
                        )
                    }
                    if settings.metricSettings.heartRateZones.method == .heartRateReserve {
                        Stepper(
                            "Resting: \(Int(settings.metricSettings.heartRateZones.restingHeartRateBPM)) bpm",
                            value: $settings.metricSettings.heartRateZones.restingHeartRateBPM,
                            in: 30...120
                        )
                    }
                    if settings.metricSettings.heartRateZones.method == .manual {
                        ForEach(settings.metricSettings.heartRateZones.manualUpperBoundsBPM.indices, id: \.self) { index in
                            Stepper(
                                "Zone \(index + 1) upper: \(Int(settings.metricSettings.heartRateZones.manualUpperBoundsBPM[index])) bpm",
                                value: $settings.metricSettings.heartRateZones.manualUpperBoundsBPM[index],
                                in: 60...230
                            )
                        }
                    }
                    Text("Zones are for personal analysis and are not medical guidance.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Export defaults") {
                    ForEach(ExportFormat.allCases) { format in
                        Toggle(
                            format.displayName,
                            isOn: Binding(
                                get: { settings.defaultFormats.contains(format) },
                                set: { enabled in
                                    if enabled {
                                        settings.defaultFormats.insert(format)
                                    } else {
                                        settings.defaultFormats.remove(format)
                                    }
                                }
                            )
                        )
                    }
                    Toggle("Package as ZIP", isOn: $settings.packageAsZIP)
                    Toggle("Include raw samples", isOn: $settings.includeRawSamples)
                    Toggle("Include source/device metadata", isOn: $settings.includeSourceMetadata)
                    Picker("Filename", selection: $settings.filenameFormat) {
                        ForEach(ExportFilenameFormat.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    LabeledContent("Schema version", value: ExportSchema.version)
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
            .toolbar { Button("Done") { settings.persist(); dismiss() } }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
            .onDisappear { settings.persist() }
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
