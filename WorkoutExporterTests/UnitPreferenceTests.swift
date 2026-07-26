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

    func testExportOptionsAndFilenamePreferencesRoundTrip() throws {
        var options = ExportOptions()
        options.filenameFormat = .activityDateIdentifier
        XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(options)), options)
    }
}
