import XCTest
@testable import WorkoutExporter

final class MetricEngineTests: XCTestCase {
    func testCleanRouteProducesDistancePaceElevationAndHeartRate() async throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)

        XCTAssertGreaterThan(metrics.routeDistanceMeters?.value ?? 0, 1_000)
        XCTAssertGreaterThan(metrics.speedThresholdMovingTime?.value ?? 0, 0)
        XCTAssertGreaterThan(metrics.averageSpeedMetersPerSecond?.value ?? 0, 0)
        XCTAssertEqual(metrics.rawElevationGainMeters?.value, detail.summary.elevationGainMeters)
        XCTAssertEqual(metrics.rawElevationGainMeters?.provenance, .healthKitStatistic)
        XCTAssertNil(metrics.smoothedElevationGainMeters)
        XCTAssertEqual(metrics.averageHeartRateBPM?.value, detail.summary.averageHeartRateBPM)
        XCTAssertEqual(metrics.averageHeartRateBPM?.provenance, .healthKitStatistic)
        XCTAssertFalse(metrics.splits.isEmpty)
    }

    func testImplausibleJumpIsPreservedButExcluded() async throws {
        let detail = SyntheticWorkoutFactory.make(.implausibleGPSJump)
        XCTAssertTrue(detail.routePoints.contains { $0.qualityFlags.contains("implausibleJumpCandidate") })

        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)
        XCTAssertTrue(metrics.warnings.contains { $0.localizedCaseInsensitiveContains("implausible") })
        XCTAssertLessThan(metrics.routeDistanceMeters?.value ?? .infinity, 100_000)
    }

    func testPoorAccuracyIsExcludedAndWarned() async throws {
        let metrics = try await WorkoutMetricCalculator().calculate(
            detail: SyntheticWorkoutFactory.make(.poorGPS)
        )
        XCTAssertTrue(metrics.warnings.contains { $0.localizedCaseInsensitiveContains("accuracy") })
    }

    func testEventAwareMovingTimeSubtractsPause() async throws {
        let detail = SyntheticWorkoutFactory.make(.walkWithAutoPause)
        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)
        XCTAssertEqual(metrics.eventAwareMovingTime?.value ?? -1, detail.summary.duration - 120, accuracy: 0.001)
    }

    func testNoRouteStillProducesEventAwareTime() async throws {
        let metrics = try await WorkoutMetricCalculator().calculate(
            detail: SyntheticWorkoutFactory.make(.noRoute)
        )
        XCTAssertNil(metrics.routeDistanceMeters)
        XCTAssertNotNil(metrics.eventAwareMovingTime)
        XCTAssertTrue(metrics.warnings.contains { $0.localizedCaseInsensitiveContains("no route") })
    }

    func testAllFifteenScenariosAreDeterministicAndUnique() {
        let fixtures = SyntheticWorkoutFactory.makeAll()
        XCTAssertEqual(fixtures.count, 15)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, 15)
        XCTAssertEqual(Set(fixtures.compactMap { $0.metadata["fixture"] }).count, 15)
        XCTAssertEqual(
            fixtures.map(\.id),
            SyntheticWorkoutFactory.makeAll().map(\.id)
        )
    }
}
