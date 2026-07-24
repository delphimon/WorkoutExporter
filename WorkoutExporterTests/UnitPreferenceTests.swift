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
}
