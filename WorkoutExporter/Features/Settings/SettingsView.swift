import SwiftUI

struct SettingsView: View {
    @Environment(UserSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacy = false
    @State private var showAdvancedMetrics = false
    @State private var isRequestingHealthAccess = false
    @State private var healthAccessMessage: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Distance, pace, and elevation", selection: $settings.distanceUnits) {
                        ForEach(DistanceUnitPreference.allCases, id: \.self) { Text($0.label).tag($0) }
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
                                "Length: " + MeasurementFormatterFactory.distanceSliderValue(
                                    settings.metricSettings.splitDistanceMeters,
                                    preference: settings.distanceUnits
                                )
                            )
                            Slider(
                                value: splitDistanceBinding,
                                in: splitDistanceRange,
                                step: settings.distanceUnits.distanceSliderStep
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
                        Toggle(
                            "Estimate maximum HR from Health age",
                            isOn: $settings.metricSettings.heartRateZones
                                .automaticallyEstimateMaximumHeartRate
                        )
                        Stepper(
                            (
                                settings.metricSettings.heartRateZones
                                    .automaticallyEstimateMaximumHeartRate
                                    ? "Fallback maximum: "
                                    : "Maximum: "
                            )
                                + "\(Int(settings.metricSettings.heartRateZones.maximumHeartRateBPM)) bpm",
                            value: $settings.metricSettings.heartRateZones.maximumHeartRateBPM,
                            in: 100...240
                        )
                        Text(
                            "When enabled and date of birth is accessible, the app estimates "
                                + "maximum HR for the workout date using "
                                + "\(AgeBasedMaximumHeartRateEstimate.formula). "
                                + "The result and zone boundaries are rounded to whole BPM. "
                                + "The configured value is used when Health access is unavailable."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    Picker("Default export", selection: $settings.defaultExportPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Text(settings.defaultExportPreset.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if settings.defaultExportPreset == .custom {
                        ForEach(ExportFormat.allCases) { format in
                            Toggle(
                                format.displayName,
                                isOn: Binding(
                                    get: { settings.defaultFormats.contains(format) },
                                    set: { enabled in
                                        updateDefaultFormat(format, enabled: enabled)
                                    }
                                )
                            )
                        }
                        if !settings.defaultFormats.contains(.activityPackage) {
                            Toggle("Package as ZIP", isOn: $settings.packageAsZIP)
                        }
                        Toggle("Include raw samples", isOn: $settings.includeRawSamples)
                        Toggle("Include source/device metadata", isOn: $settings.includeSourceMetadata)
                    }
                    Picker("Filename", selection: $settings.filenameFormat) {
                        ForEach(ExportFilenameFormat.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    LabeledContent("Schema version", value: ExportSchema.version)
                }
                Section("Privacy") {
                    Button("How your data is handled") { showPrivacy = true }
                    Button {
                        requestHealthAccess()
                    } label: {
                        if isRequestingHealthAccess {
                            Label("Reviewing Health Access…", systemImage: "heart.text.square")
                        } else {
                            Label("Review Health Access", systemImage: "heart.text.square")
                        }
                    }
                    .disabled(isRequestingHealthAccess)
                    if let healthAccessMessage {
                        Text(healthAccessMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Heart-rate zones and derived metrics are for personal analysis, not medical guidance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup(
                        "Advanced metric calculation",
                        isExpanded: $showAdvancedMetrics
                    ) {
                        VStack(alignment: .leading) {
                            Text(
                                "Moving threshold: "
                                    + MeasurementFormatterFactory.speed(
                                        settings.metricSettings.movingSpeedThresholdMetersPerSecond,
                                        preference: settings.distanceUnits
                                    )
                            )
                            Slider(
                                value: $settings.metricSettings.movingSpeedThresholdMetersPerSecond,
                                in: 0.2...3,
                                step: 0.05
                            )
                            Text(
                                "Segments below this speed are treated as stopped. "
                                    + "This changes the Pace chart, Moving Pace, "
                                    + "split moving time, and derived export fields."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("Minimum moving interval: \(Int(settings.metricSettings.minimumMovingDuration)) seconds")
                            Slider(
                                value: $settings.metricSettings.minimumMovingDuration,
                                in: 1...30,
                                step: 1
                            )
                            Text(
                                "A continuous above-threshold burst must last this long "
                                    + "to count toward Moving Pace and split moving time."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("Stopped interval: \(Int(settings.metricSettings.minimumStoppedDuration)) seconds")
                            Slider(
                                value: $settings.metricSettings.minimumStoppedDuration,
                                in: 1...30,
                                step: 1
                            )
                            Text(
                                "A below-threshold interval shorter than this stays in "
                                    + "derived moving time; a longer interval counts as stopped."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("Route gap: \(Int(settings.metricSettings.maximumRouteGap)) seconds")
                            Slider(
                                value: $settings.metricSettings.maximumRouteGap,
                                in: 5...120,
                                step: 5
                            )
                            Text(
                                "Points farther apart in time are not connected when "
                                    + "calculating derived distance, speed, pace, elevation "
                                    + "loss, or splits."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Text(
                            "These settings only recalculate supplemental values. "
                                + "They never alter HealthKit totals, timestamps, samples, "
                                + "route points, or recorded elevation gain. Summary Moving "
                                + "Time uses recorded pause/resume events, so it is unchanged."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("advanced-metric-settings")
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

    private func updateDefaultFormat(_ format: ExportFormat, enabled: Bool) {
        if enabled, format == .activityPackage {
            settings.defaultFormats = [.activityPackage]
            settings.packageAsZIP = false
        } else if enabled {
            settings.defaultFormats.remove(.activityPackage)
            settings.defaultFormats.insert(format)
        } else {
            settings.defaultFormats.remove(format)
        }
    }

    private func requestHealthAccess() {
        isRequestingHealthAccess = true
        healthAccessMessage = nil
        Task {
            defer { isRequestingHealthAccess = false }
            do {
                try await environment.healthClient.requestReadAuthorization()
                healthAccessMessage =
                    "Health access review completed. Health does not report "
                    + "which read permissions were granted."
            } catch {
                healthAccessMessage = error.localizedDescription
            }
        }
    }

    private var splitDistanceBinding: Binding<Double> {
        Binding(
            get: {
                settings.distanceUnits.distanceValue(
                    fromMeters: settings.metricSettings.splitDistanceMeters
                )
            },
            set: {
                settings.metricSettings.splitDistanceMeters =
                    settings.distanceUnits.meters(fromDistanceValue: $0)
            }
        )
    }

    private var splitDistanceRange: ClosedRange<Double> {
        settings.distanceUnits == .metric ? 0.4...5.0 : 0.2...3.1
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
                    Text("Activity Manager does not transmit workout data to the developer.")
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
