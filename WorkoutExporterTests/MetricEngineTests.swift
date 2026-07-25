import XCTest
@testable import WorkoutExporter

final class MetricEngineTests: XCTestCase {
    func testCleanRouteProducesDistancePaceElevationAndHeartRate() async throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)

        XCTAssertGreaterThan(metrics.routeDistanceMeters?.value ?? 0, 1_000)
        XCTAssertGreaterThan(metrics.speedThresholdMovingTime?.value ?? 0, 0)
        XCTAssertGreaterThan(metrics.averageSpeedMetersPerSecond?.value ?? 0, 0)
        XCTAssertEqual(
            metrics.maximumSpeedMetersPerSecond?.value,
            detail.routePoints.compactMap(\.speedMetersPerSecond).max()
        )
        XCTAssertEqual(metrics.maximumSpeedMetersPerSecond?.provenance, .location)
        XCTAssertEqual(metrics.rawElevationGainMeters?.value, detail.summary.elevationGainMeters)
        XCTAssertEqual(metrics.rawElevationGainMeters?.provenance, .healthKitStatistic)
        XCTAssertEqual(metrics.averageHeartRateBPM?.value, detail.summary.averageHeartRateBPM)
        XCTAssertEqual(metrics.averageHeartRateBPM?.provenance, .healthKitStatistic)
        XCTAssertEqual(metrics.routeMetrics?.count, detail.routePoints.count)
        XCTAssertEqual(metrics.routeMetrics?.first?.cumulativeDistanceMeters, 0)
        XCTAssertTrue(metrics.routeMetrics?.dropFirst().contains { $0.derivedSpeedMetersPerSecond != nil } == true)
        XCTAssertEqual(
            metrics.heartRateZones?.map(\.duration).reduce(0, +) ?? -1,
            detail.summary.duration - 5,
            accuracy: 1
        )
        XCTAssertFalse(metrics.splits.isEmpty)
    }

    func testHikePreservesNativeElevationGain() async throws {
        let detail = SyntheticWorkoutFactory.make(.hikeWithStops)
        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)

        XCTAssertEqual(metrics.rawElevationGainMeters?.value, 420)
        XCTAssertEqual(metrics.rawElevationGainMeters?.provenance, .healthKitStatistic)
        XCTAssertEqual(detail.summary.elevationGainMeters, 420)
    }

    func testNativeWorkoutValuesRemainUnchangedWhenDerivedValuesDiffer() async throws {
        let detail = SyntheticWorkoutFactory.make(.conflictingDistance)
        let originalSummary = detail.summary
        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)

        XCTAssertEqual(detail.summary, originalSummary)
        XCTAssertEqual(metrics.rawElevationGainMeters?.value, originalSummary.elevationGainMeters)
        XCTAssertEqual(metrics.rawElevationGainMeters?.provenance, .healthKitStatistic)
        XCTAssertNotEqual(metrics.routeDistanceMeters?.value, originalSummary.totalDistanceMeters)
        XCTAssertEqual(metrics.routeDistanceMeters?.provenance, .routeDerived)
    }

    func testElapsedTimeSplitsAndManualHeartRateZones() async throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.metricSettings.splitMode = .elapsedTime
        detail.metricSettings.splitElapsedTime = 900
        detail.metricSettings.heartRateZones.method = .manual
        detail.metricSettings.heartRateZones.manualUpperBoundsBPM = [130, 140, 150, 160]

        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)

        XCTAssertGreaterThanOrEqual(metrics.splits.count, 3)
        XCTAssertTrue(metrics.splits.dropLast().allSatisfy { $0.elapsedTime >= 900 })
        XCTAssertEqual(metrics.heartRateZones?.count, 5)
        XCTAssertEqual(metrics.heartRateZones?[0].upperBoundBPM, 130)
        XCTAssertEqual(metrics.heartRateZones?[4].lowerBoundBPM, 160)
    }

    func testMetricSettingsDecodeOlderExportsWithConservativeDefaults() throws {
        let data = Data(#"{"movingSpeedThresholdMetersPerSecond":1.25}"#.utf8)
        let settings = try JSONDecoder().decode(MetricCalculationSettings.self, from: data)

        XCTAssertEqual(settings.movingSpeedThresholdMetersPerSecond, 1.25)
        XCTAssertEqual(settings.minimumStoppedDuration, 5)
        XCTAssertEqual(settings.splitMode, .distance)
        XCTAssertEqual(settings.heartRateZones.method, .percentMaximum)
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
