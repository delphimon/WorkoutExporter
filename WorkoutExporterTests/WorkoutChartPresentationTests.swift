import XCTest
@testable import WorkoutExporter

final class WorkoutChartPresentationTests: XCTestCase {
    func testLongWorkoutUsesBoundedDisplaySeriesWithoutChangingSourceData() throws {
        let detail = SyntheticWorkoutFactory.make(.veryLongWorkout)
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

    func testNearestPointLookupReturnsOriginalSampleAtSelectedTime() throws {
        let detail = SyntheticWorkoutFactory.make(.veryLongWorkout)
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
}
