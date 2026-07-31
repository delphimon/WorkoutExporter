import XCTest
@testable import WorkoutExporter

final class WorkoutChartPresentationTests: XCTestCase {
    func testLongWorkoutUsesBoundedDisplaySeriesWithoutChangingSourceData() async throws {
        let detail = try await calculatedDetail(.veryLongWorkout)
        let originalRoute = try XCTUnwrap(detail.routes.values.first)
        let originalHeartRate = detail.heartRateSamples

        let presentation = WorkoutChartPresentation(detail: detail)

        XCTAssertEqual(presentation.routePoints.count, originalRoute.count)
        XCTAssertEqual(presentation.routePoints.first?.id, originalRoute.first?.id)
        XCTAssertEqual(presentation.routePoints.last?.id, originalRoute.last?.id)
        XCTAssertLessThanOrEqual(
            presentation.elevationPoints.count,
            WorkoutChartPresentation.chartPointLimit
        )
        XCTAssertLessThanOrEqual(
            presentation.pacePoints.count,
            WorkoutChartPresentation.chartPointLimit
        )
        XCTAssertFalse(presentation.elevationPoints.isEmpty)
        XCTAssertFalse(presentation.pacePoints.isEmpty)
        XCTAssertLessThanOrEqual(
            presentation.mapRoutes.flatMap(\.points).count,
            WorkoutChartPresentation.mapPointLimit
        )
        XCTAssertLessThanOrEqual(
            presentation.heartRateSamples.count,
            WorkoutChartPresentation.chartPointLimit
        )
        XCTAssertFalse(presentation.heartRateSamples.isEmpty)
        XCTAssertEqual(
            presentation.heartRateSamples.map(\.value).min(),
            originalHeartRate.map(\.value).min()
        )
        XCTAssertEqual(
            presentation.heartRateSamples.map(\.value).max(),
            originalHeartRate.map(\.value).max()
        )
        XCTAssertEqual(
            presentation.elevationPoints.map(\.altitudeMeters).min(),
            originalRoute.map(\.altitudeMeters).min()
        )
        XCTAssertEqual(
            presentation.elevationPoints.map(\.altitudeMeters).max(),
            originalRoute.map(\.altitudeMeters).max()
        )
        XCTAssertEqual(detail.routes.values.first, originalRoute)
        XCTAssertEqual(detail.heartRateSamples, originalHeartRate)
    }

    func testNearestPointLookupReturnsOriginalSampleAtSelectedTime() async throws {
        let detail = try await calculatedDetail(.veryLongWorkout)
        let originalRoute = try XCTUnwrap(detail.routes.values.first)
        let presentation = WorkoutChartPresentation(detail: detail)
        let expected = originalRoute[7_500]

        let selected = try XCTUnwrap(
            presentation.nearestRoutePoint(to: expected.timestamp)
        )

        XCTAssertEqual(selected.id, expected.id)
        XCTAssertEqual(selected.altitudeMeters, expected.altitudeMeters)
        XCTAssertEqual(selected.latitude, expected.latitude)
        XCTAssertEqual(selected.longitude, expected.longitude)
    }

    func testChartDomainsAreFixedAndContainEveryDisplayedValue() async throws {
        let presentation = WorkoutChartPresentation(
            detail: try await calculatedDetail(.veryLongWorkout)
        )
        let heartRateDomain = try XCTUnwrap(presentation.heartRateDomain)
        let paceDomain = try XCTUnwrap(presentation.paceDomain)
        let elevationDomain = try XCTUnwrap(presentation.elevationDomain)

        XCTAssertTrue(
            presentation.heartRateSamples.allSatisfy {
                heartRateDomain.date.contains($0.startDate)
                    && heartRateDomain.value.contains($0.value)
            }
        )
        XCTAssertTrue(
            presentation.pacePoints.allSatisfy {
                guard let pace = $0.rawPaceSecondsPerKilometer else {
                    return false
                }
                return paceDomain.date.contains($0.timestamp)
                    && paceDomain.value.contains(pace)
            }
        )
        XCTAssertTrue(
            presentation.elevationPoints.allSatisfy {
                elevationDomain.date.contains($0.timestamp)
                    && elevationDomain.value.contains($0.altitudeMeters)
            }
        )

        let firstDate = try XCTUnwrap(
            presentation.elevationPoints.first?.timestamp
        )
        let lastDate = try XCTUnwrap(
            presentation.elevationPoints.last?.timestamp
        )
        _ = presentation.nearestElevationPoint(to: firstDate)
        _ = presentation.nearestElevationPoint(to: lastDate)

        XCTAssertEqual(presentation.heartRateDomain, heartRateDomain)
        XCTAssertEqual(presentation.paceDomain, paceDomain)
        XCTAssertEqual(presentation.elevationDomain, elevationDomain)
    }

    func testPacePresentationExcludesBelowThresholdArtifactsWithoutChangingRoute() async throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let routeID = try XCTUnwrap(detail.routes.keys.first)
        var route = try XCTUnwrap(detail.routes[routeID])
        route[80].latitude = route[79].latitude + 0.000_000_000_001
        route[80].longitude = route[79].longitude + 0.000_000_000_001
        let artifactPoint = route[80]
        detail.routes[routeID] = route
        detail.derived = try await WorkoutMetricCalculator().calculate(detail: detail)

        let artifactMetric = try XCTUnwrap(
            detail.derived.routeMetrics?.first {
                $0.routePointID == artifactPoint.id
            }
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(artifactMetric.rawPaceSecondsPerKilometer),
            1_000_000
        )

        let presentation = WorkoutChartPresentation(detail: detail)

        XCTAssertFalse(
            presentation.pacePoints.contains {
                $0.routePointID == artifactPoint.id
            }
        )
        XCTAssertTrue(
            presentation.pacePoints.allSatisfy {
                ($0.derivedSpeedMetersPerSecond ?? 0)
                    >= detail.metricSettings.movingSpeedThresholdMetersPerSecond
            }
        )
        XCTAssertEqual(detail.routes[routeID]?[80], artifactPoint)
    }

    func testActivityTimeZoneUsesRecordedWorkoutMetadata() {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.metadata["HKTimeZone"] = "America/Los_Angeles"

        XCTAssertEqual(
            detail.activityTimeZone.identifier,
            "America/Los_Angeles"
        )
    }

    private func calculatedDetail(
        _ scenario: SyntheticWorkoutScenario
    ) async throws -> WorkoutDetail {
        var detail = SyntheticWorkoutFactory.make(scenario)
        detail.derived = try await WorkoutMetricCalculator().calculate(
            detail: detail
        )
        return detail
    }
}
