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

    func testReturningToLoadedListDoesNotReloadOrResetPagination() async {
        let workouts = (0..<120).map { index -> WorkoutSummary in
            var summary = SyntheticWorkoutFactory.make(
                .cleanOutdoorRun,
                index: index
            ).summary
            summary.id = UUID()
            return summary
        }
        let client = ListClient(workouts: workouts)
        let model = WorkoutListViewModel()

        await model.loadIfNeeded(
            using: client,
            isUsingSyntheticData: false
        )
        await model.loadMore(using: client)
        XCTAssertEqual(model.workouts.count, 100)
        XCTAssertEqual(model.requestedLimit, 100)
        var requestedLimits = await client.requestedLimits()
        XCTAssertEqual(requestedLimits, [50, 100])

        await model.loadIfNeeded(
            using: client,
            isUsingSyntheticData: false
        )

        XCTAssertEqual(model.workouts.count, 100)
        XCTAssertEqual(model.requestedLimit, 100)
        requestedLimits = await client.requestedLimits()
        XCTAssertEqual(requestedLimits, [50, 100])
    }

    func testChangingDataSourceStillPerformsFreshInitialLoad() async {
        let liveClient = ListClient(
            workouts: (0..<80).map {
                SyntheticWorkoutFactory.make(
                    .cleanOutdoorRun,
                    index: $0
                ).summary
            }
        )
        let syntheticClient = ListClient(
            workouts: (0..<15).map {
                SyntheticWorkoutFactory.make(
                    .cleanOutdoorRun,
                    index: $0
                ).summary
            }
        )
        let model = WorkoutListViewModel()

        await model.loadIfNeeded(
            using: liveClient,
            isUsingSyntheticData: false
        )
        await model.loadMore(using: liveClient)
        XCTAssertEqual(model.requestedLimit, 100)

        await model.loadIfNeeded(
            using: syntheticClient,
            isUsingSyntheticData: true
        )

        XCTAssertEqual(model.workouts.count, 15)
        XCTAssertEqual(model.requestedLimit, 50)
        XCTAssertEqual(model.loadedDataSourceIsSynthetic, true)
        let requestedLimits = await syntheticClient.requestedLimits()
        XCTAssertEqual(requestedLimits, [50])
    }

    func testLoadMoreSearchesUntilAFilteredMatchOrActualEnd() async {
        let workouts = (0..<120).map { index -> WorkoutSummary in
            var summary = SyntheticWorkoutFactory.make(
                .cleanOutdoorRun,
                index: index
            ).summary
            summary.id = UUID()
            summary.activityName = index < 100 ? "Running" : "Hiking"
            return summary
        }
        let client = ListClient(workouts: workouts)
        let model = WorkoutListViewModel()

        await model.load(using: client)
        model.selectedActivity = "Hiking"
        XCTAssertTrue(model.filteredWorkouts.isEmpty)

        await model.loadMore(using: client)

        XCTAssertEqual(model.filteredWorkouts.count, 20)
        XCTAssertFalse(model.canLoadMore)
        let requestedLimits = await client.requestedLimits()
        XCTAssertEqual(requestedLimits, [50, 100, 150])
    }

    func testDateRangesIncludeThisMonthTwelveMonthsAndInclusiveCustomDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 25,
                hour: 12
            )
        )!
        func summary(year: Int, month: Int, day: Int) -> WorkoutSummary {
            var value = SyntheticWorkoutFactory.make(.cleanOutdoorRun).summary
            value.id = UUID()
            value.startDate = calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: 8)
            )!
            value.endDate = value.startDate.addingTimeInterval(value.duration)
            return value
        }
        let model = WorkoutListViewModel()
        model.workouts = [
            summary(year: 2026, month: 7, day: 1),
            summary(year: 2026, month: 6, day: 30),
            summary(year: 2025, month: 8, day: 1),
            summary(year: 2025, month: 6, day: 1)
        ]

        model.dateRange = .thisMonth
        XCTAssertEqual(
            model.filteredWorkouts(referenceDate: reference, calendar: calendar).count,
            1
        )

        model.dateRange = .twelveMonths
        XCTAssertEqual(
            model.filteredWorkouts(referenceDate: reference, calendar: calendar).count,
            3
        )

        model.dateRange = .custom
        model.customStartDate = calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 30, hour: 23)
        )!
        model.customEndDate = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 1, hour: 1)
        )!
        XCTAssertEqual(
            model.filteredWorkouts(referenceDate: reference, calendar: calendar).count,
            2
        )
    }

    func testStatsUseNativeSummaryValuesGroupedByActivityType() throws {
        var first = SyntheticWorkoutFactory.make(.cleanOutdoorRun, index: 1).summary
        first.activityName = "Running"
        first.totalDistanceMeters = 1_000
        first.duration = 600
        first.elevationGainMeters = 40
        var second = SyntheticWorkoutFactory.make(.cleanOutdoorRun, index: 2).summary
        second.activityName = "Running"
        second.totalDistanceMeters = nil
        second.duration = 300
        second.elevationGainMeters = 10
        var hike = SyntheticWorkoutFactory.make(.hikeWithStops, index: 3).summary
        hike.activityName = "Hiking"
        hike.totalDistanceMeters = 2_000
        hike.duration = 1_200
        hike.elevationGainMeters = nil

        let groups = WorkoutStatsCalculator.group([first, second, hike])
        let running = try XCTUnwrap(groups.first { $0.activityName == "Running" })
        XCTAssertEqual(running.count, 2)
        XCTAssertEqual(running.totalDistanceMeters, 1_000)
        XCTAssertEqual(running.totalDuration, 900)
        XCTAssertEqual(running.totalElevationGainMeters, 50)
        let hiking = try XCTUnwrap(groups.first { $0.activityName == "Hiking" })
        XCTAssertEqual(hiking.totalDistanceMeters, 2_000)
        XCTAssertEqual(hiking.totalDuration, 1_200)
        XCTAssertNil(hiking.totalElevationGainMeters)
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
    private var limits: [Int] = []

    init(workouts: [WorkoutSummary]) {
        self.workouts = workouts
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        limits.append(limit)
        return Array(workouts.prefix(limit))
    }

    func requestedLimits() -> [Int] {
        limits
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
