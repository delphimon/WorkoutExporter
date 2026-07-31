import Foundation
import Observation

@MainActor
@Observable
final class WorkoutListViewModel {
    enum SortOrder: String, CaseIterable {
        case newestFirst = "Newest first"
        case oldestFirst = "Oldest first"
        case longestDuration = "Longest duration"
        case longestDistance = "Longest distance"
    }

    enum DateRange: String, CaseIterable {
        case all = "All dates"
        case sevenDays = "Last 7 days"
        case thisMonth = "This month"
        case thirtyDays = "Last 30 days"
        case ninetyDays = "Last 90 days"
        case twelveMonths = "Last 12 months"
        case custom = "Custom dates"
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var workouts: [WorkoutSummary] = []
    var state: LoadState = .idle
    var searchText = ""
    var selectedActivity = "All"
    var selectedSource = "All"
    var dateRange = DateRange.all
    var customStartDate = Calendar.current.date(
        byAdding: .month,
        value: -1,
        to: Date()
    ) ?? Date()
    var customEndDate = Date()
    var sortOrder = SortOrder.newestFirst
    var routeOnly = false
    var heartRateOnly = false
    var unexportedOnly = false
    var minimumDurationMinutes = 0.0
    var minimumDistanceMeters = 0.0
    var selectedIDs: Set<UUID> = []
    var exportedWorkoutIDs: Set<UUID> = []
    var customLocationTags: [UUID: String] = [:]
    var isSelecting = false
    private(set) var requestedLimit = 50
    private(set) var canLoadMore = true
    private(set) var isLoadingMore = false
    private(set) var isLoadingAll = false
    private(set) var paginationError: String?
    private(set) var loadedDataSourceIsSynthetic: Bool?

    var activityOptions: [String] {
        ["All"] + Set(workouts.map(\.activityName)).sorted()
    }

    var sourceOptions: [String] {
        ["All"] + Set(workouts.map(\.source.name)).sorted()
    }

    var filteredWorkouts: [WorkoutSummary] {
        filteredWorkouts(referenceDate: Date(), calendar: .current)
    }

    func filteredWorkouts(
        referenceDate: Date,
        calendar: Calendar
    ) -> [WorkoutSummary] {
        let interval = dateInterval(referenceDate: referenceDate, calendar: calendar)
        let filtered = workouts.filter { workout in
            let matchesText = searchText.isEmpty
                || workout.activityName.localizedCaseInsensitiveContains(searchText)
                || workout.source.name.localizedCaseInsensitiveContains(searchText)
                || customLocationTags[workout.id]?.localizedCaseInsensitiveContains(searchText) == true
            let matchesActivity = selectedActivity == "All" || workout.activityName == selectedActivity
            let matchesSource = selectedSource == "All" || workout.source.name == selectedSource
            let matchesDate = interval.map { $0.contains(workout.startDate) } ?? true
            let matchesRoute = !routeOnly || workout.hasRoute
            let matchesHeartRate = !heartRateOnly || workout.averageHeartRateBPM != nil
            let matchesExportStatus = !unexportedOnly
                || !exportedWorkoutIDs.contains(workout.id)
            let matchesDuration = workout.duration >= minimumDurationMinutes * 60
            let matchesDistance = (workout.totalDistanceMeters ?? 0) >= minimumDistanceMeters
            return matchesText && matchesActivity && matchesSource && matchesDate
                && matchesRoute && matchesHeartRate && matchesExportStatus
                && matchesDuration && matchesDistance
        }
        return filtered.sorted {
            switch sortOrder {
            case .newestFirst: $0.startDate > $1.startDate
            case .oldestFirst: $0.startDate < $1.startDate
            case .longestDuration: $0.duration > $1.duration
            case .longestDistance: ($0.totalDistanceMeters ?? 0) > ($1.totalDistanceMeters ?? 0)
            }
        }
    }

    func dateInterval(
        referenceDate: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let endOfToday = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: referenceDate)
        ) ?? referenceDate
        let start: Date?
        switch dateRange {
        case .all:
            return nil
        case .sevenDays:
            start = calendar.date(byAdding: .day, value: -7, to: referenceDate)
        case .thisMonth:
            start = calendar.date(
                from: calendar.dateComponents([.year, .month], from: referenceDate)
            )
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -30, to: referenceDate)
        case .ninetyDays:
            start = calendar.date(byAdding: .day, value: -90, to: referenceDate)
        case .twelveMonths:
            start = calendar.date(byAdding: .month, value: -12, to: referenceDate)
        case .custom:
            let lower = min(customStartDate, customEndDate)
            let upper = max(customStartDate, customEndDate)
            let inclusiveEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: upper)
            ) ?? upper
            return DateInterval(
                start: calendar.startOfDay(for: lower),
                end: inclusiveEnd
            )
        }
        return start.map { DateInterval(start: $0, end: endOfToday) }
    }

    func load(using client: any HealthKitClient, resetLimit: Bool = true) async {
        if resetLimit { requestedLimit = 50 }
        paginationError = nil
        state = .loading
        do {
            let loaded = try await client.fetchWorkouts(limit: requestedLimit)
            workouts = loaded
            canLoadMore = loaded.count == requestedLimit
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func loadIfNeeded(
        using client: any HealthKitClient,
        isUsingSyntheticData: Bool
    ) async {
        guard state == .idle
                || loadedDataSourceIsSynthetic != isUsingSyntheticData else {
            return
        }
        loadedDataSourceIsSynthetic = isUsingSyntheticData
        await load(using: client)
    }

    func loadMore(using client: any HealthKitClient) async {
        guard canLoadMore, state == .loaded, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let priorMatchCount = filteredWorkouts.count
        paginationError = nil
        while canLoadMore, filteredWorkouts.count == priorMatchCount {
            let nextLimit = requestedLimit + 50
            do {
                let loaded = try await client.fetchWorkouts(limit: nextLimit)
                workouts = loaded
                requestedLimit = nextLimit
                canLoadMore = loaded.count == nextLimit
            } catch {
                paginationError = error.localizedDescription
                return
            }
        }
    }

    func loadAll(using client: any HealthKitClient) async {
        guard canLoadMore, state == .loaded, !isLoadingAll else { return }
        isLoadingAll = true
        defer { isLoadingAll = false }
        paginationError = nil
        while canLoadMore {
            let nextLimit = requestedLimit + 200
            do {
                let loaded = try await client.fetchWorkouts(limit: nextLimit)
                workouts = loaded
                requestedLimit = nextLimit
                canLoadMore = loaded.count == nextLimit
            } catch {
                paginationError = error.localizedDescription
                return
            }
            await Task.yield()
        }
    }

    func resetFilters() {
        selectedActivity = "All"
        selectedSource = "All"
        dateRange = .all
        sortOrder = .newestFirst
        routeOnly = false
        heartRateOnly = false
        unexportedOnly = false
        minimumDurationMinutes = 0
        minimumDistanceMeters = 0
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func selectAllFiltered() {
        selectedIDs.formUnion(filteredWorkouts.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }
}
