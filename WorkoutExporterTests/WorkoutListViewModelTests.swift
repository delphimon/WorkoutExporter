import XCTest
@testable import WorkoutExporter

@MainActor
final class WorkoutListViewModelTests: XCTestCase {
    func testFiltersSortAndResetCoverListRequirements() async {
        let fixtures = SyntheticWorkoutFactory.makeAll().map(\.summary)
        let model = WorkoutListViewModel()
        await model.load(using: ListClient(workouts: fixtures))

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.workouts.count, fixtures.count)

        model.selectedActivity = "Hiking"
        model.routeOnly = true
        model.heartRateOnly = true
        model.minimumDurationMinutes = 30
        model.minimumDistanceMeters = 1_000
        XCTAssertTrue(model.filteredWorkouts.allSatisfy {
            $0.activityName == "Hiking"
                && $0.hasRoute
                && $0.averageHeartRateBPM != nil
                && $0.duration >= 1_800
                && ($0.totalDistanceMeters ?? 0) >= 1_000
        })

        model.resetFilters()
        model.sortOrder = .longestDuration
        XCTAssertEqual(model.filteredWorkouts.first?.duration, fixtures.map(\.duration).max())
        XCTAssertEqual(model.selectedActivity, "All")
        XCTAssertFalse(model.routeOnly)
        XCTAssertFalse(model.heartRateOnly)
    }

    func testPaginationRequestsIncreasingLimits() async {
        let workouts = (0..<120).map { index -> WorkoutSummary in
            var summary = SyntheticWorkoutFactory.make(.cleanOutdoorRun, index: index).summary
            summary.id = UUID()
            return summary
        }
        let client = ListClient(workouts: workouts)
        let model = WorkoutListViewModel()

        await model.load(using: client)
        XCTAssertEqual(model.workouts.count, 50)
        XCTAssertTrue(model.canLoadMore)

        await model.loadMore(using: client)
        XCTAssertEqual(model.workouts.count, 100)
        XCTAssertTrue(model.canLoadMore)

        await model.loadMore(using: client)
        XCTAssertEqual(model.workouts.count, 120)
        XCTAssertFalse(model.canLoadMore)
    }

    func testPaginationFailureKeepsLoadedWorkoutsAndLimit() async {
        let workouts = (0..<60).map {
            SyntheticWorkoutFactory.make(.cleanOutdoorRun, index: $0).summary
        }
        let model = WorkoutListViewModel()
        await model.load(using: FailingPaginationClient(workouts: workouts))

        await model.loadMore(using: FailingPaginationClient(workouts: workouts))

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.workouts.count, 50)
        XCTAssertEqual(model.requestedLimit, 50)
        XCTAssertNotNil(model.paginationError)
    }

    func testUnexportedFilterManualLocationSearchAndBulkSelection() async throws {
        let fixtures = SyntheticWorkoutFactory.makeAll().map(\.summary)
        let first = try XCTUnwrap(fixtures.first)
        let second = try XCTUnwrap(fixtures.dropFirst().first)
        let model = WorkoutListViewModel()
        await model.load(using: ListClient(workouts: fixtures))
        model.exportedWorkoutIDs = [first.id]
        model.customLocationTags[second.id] = "Green Lake"

        model.unexportedOnly = true
        XCTAssertFalse(model.filteredWorkouts.contains { $0.id == first.id })
        XCTAssertTrue(model.filteredWorkouts.contains { $0.id == second.id })

        model.searchText = "Green Lake"
        XCTAssertEqual(model.filteredWorkouts.map(\.id), [second.id])
        model.selectAllFiltered()
        XCTAssertEqual(model.selectedIDs, Set([second.id]))

        model.clearSelection()
        XCTAssertTrue(model.selectedIDs.isEmpty)
        model.resetFilters()
        XCTAssertFalse(model.unexportedOnly)
    }
}

private actor ListClient: HealthKitClient {
    nonisolated let isHealthDataAvailable = true
    let workouts: [WorkoutSummary]

    init(workouts: [WorkoutSummary]) {
        self.workouts = workouts
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        Array(workouts.prefix(limit))
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        throw WorkoutExporterError.noAccessibleData
    }
}

private actor FailingPaginationClient: HealthKitClient {
    nonisolated let isHealthDataAvailable = true
    let workouts: [WorkoutSummary]

    init(workouts: [WorkoutSummary]) {
        self.workouts = workouts
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        guard limit <= 50 else {
            throw WorkoutExporterError.queryFailure("Synthetic pagination failure")
        }
        return Array(workouts.prefix(limit))
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        throw WorkoutExporterError.noAccessibleData
    }
}
