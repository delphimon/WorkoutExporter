import XCTest
@testable import WorkoutExporter

final class UnitPreferenceTests: XCTestCase {
    func testMetricAndUSDistanceConversion() {
        XCTAssertTrue(MeasurementFormatterFactory.distance(1_000, preference: .metric).contains("km"))
        XCTAssertTrue(MeasurementFormatterFactory.distance(1_609.344, preference: .usCustomary).contains("mi"))
    }

    func testPaceConversion() {
        let metric = MeasurementFormatterFactory.pace(secondsPerKilometer: 300, preference: .metric)
        let imperial = MeasurementFormatterFactory.pace(secondsPerKilometer: 300, preference: .usCustomary)
        XCTAssertTrue(metric.contains("/km"))
        XCTAssertTrue(imperial.contains("/mi"))
        XCTAssertNotEqual(metric, imperial)
    }

    func testElevationAndSpeedFollowSelectedUnitScheme() {
        XCTAssertTrue(MeasurementFormatterFactory.elevation(100, preference: .metric).contains("m"))
        XCTAssertTrue(MeasurementFormatterFactory.elevation(100, preference: .usCustomary).contains("ft"))
        XCTAssertTrue(MeasurementFormatterFactory.speed(1, preference: .metric).contains("km/h"))
        XCTAssertTrue(MeasurementFormatterFactory.speed(1, preference: .usCustomary).contains("mph"))
    }

    func testDistanceSliderConversionsUseRoundStepsInSelectedScheme() {
        XCTAssertEqual(
            DistanceUnitPreference.metric.meters(fromDistanceValue: 1),
            1_000,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DistanceUnitPreference.usCustomary.meters(fromDistanceValue: 1),
            1_609.344,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DistanceUnitPreference.usCustomary.distanceValue(
                fromMeters: 1_609.344
            ),
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(DistanceUnitPreference.metric.distanceSliderStep, 0.1)
        XCTAssertEqual(DistanceUnitPreference.usCustomary.distanceSliderStep, 0.1)
    }

    func testLegacyMetricSteppedMileSplitNormalizesToExactMile() {
        XCTAssertEqual(
            DistanceUnitPreference.usCustomary
                .normalizingLegacySplitDistance(1_600),
            1_609.344,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DistanceUnitPreference.metric
                .normalizingLegacySplitDistance(1_600),
            1_600,
            accuracy: 0.000_1
        )
    }

    func testCompleteSplitUsesConfiguredUnitLabelAndPartialSplitKeepsActualDistance() {
        let configuredMile = 1_609.344
        let complete = MeasurementFormatterFactory.splitDistance(
            actualMeters: configuredMile + 4,
            configuredDistanceMeters: configuredMile,
            preference: .usCustomary
        )
        XCTAssertTrue(complete.contains("1"))
        XCTAssertTrue(complete.contains("mi"))
        XCTAssertFalse(complete.contains("0.99"))
        XCTAssertTrue(
            MeasurementFormatterFactory.splitDistance(
                actualMeters: configuredMile / 2,
                configuredDistanceMeters: configuredMile,
                preference: .usCustomary
            ).contains("0.5")
        )
    }

    @MainActor
    func testUserSettingsMigratesLegacyMileSplitOnLoad() throws {
        let suiteName = "UnitPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            DistanceUnitPreference.usCustomary.rawValue,
            forKey: "distanceUnits"
        )
        var metricSettings = MetricCalculationSettings()
        metricSettings.splitDistanceMeters = 1_600
        defaults.set(
            try JSONEncoder().encode(metricSettings),
            forKey: "metricSettings"
        )

        let settings = UserSettings(defaults: defaults)

        XCTAssertEqual(
            settings.metricSettings.splitDistanceMeters,
            1_609.344,
            accuracy: 0.000_1
        )
    }

    func testExportOptionsAndFilenamePreferencesRoundTrip() throws {
        var options = ExportOptions()
        options.filenameFormat = .activityDateIdentifier
        options.unitScheme = .usCustomary
        XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(options)), options)
    }

    @MainActor
    func testBasicExportIsDefaultAndPresetPersists() throws {
        let suiteName = "ExportPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = UserSettings(defaults: defaults)
        XCTAssertEqual(initial.defaultExportPreset, .basic)
        XCTAssertEqual(initial.defaultFormats, [.json, .gpx])
        initial.defaultExportPreset = .detailed
        initial.persist()

        XCTAssertEqual(
            UserSettings(defaults: defaults).defaultExportPreset,
            .detailed
        )
    }
}
