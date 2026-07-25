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
        case thirtyDays = "Last 30 days"
        case oneYear = "Last year"

        var interval: TimeInterval? {
            switch self {
            case .all: nil
            case .sevenDays: 7 * 86_400
            case .thirtyDays: 30 * 86_400
            case .oneYear: 365 * 86_400
            }
        }
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
    var sortOrder = SortOrder.newestFirst
    var routeOnly = false
    var heartRateOnly = false
    var minimumDurationMinutes = 0.0
    var minimumDistanceMeters = 0.0
    var selectedIDs: Set<UUID> = []
    var isSelecting = false
    private(set) var requestedLimit = 50
    private(set) var canLoadMore = true

    var activityOptions: [String] {
        ["All"] + Set(workouts.map(\.activityName)).sorted()
    }

    var sourceOptions: [String] {
        ["All"] + Set(workouts.map(\.source.name)).sorted()
    }

    var filteredWorkouts: [WorkoutSummary] {
        let cutoff = dateRange.interval.map { Date().addingTimeInterval(-$0) }
        let filtered = workouts.filter { workout in
            let matchesText = searchText.isEmpty
                || workout.activityName.localizedCaseInsensitiveContains(searchText)
                || workout.source.name.localizedCaseInsensitiveContains(searchText)
            let matchesActivity = selectedActivity == "All" || workout.activityName == selectedActivity
            let matchesSource = selectedSource == "All" || workout.source.name == selectedSource
            let matchesDate = cutoff.map { workout.startDate >= $0 } ?? true
            let matchesRoute = !routeOnly || workout.hasRoute
            let matchesHeartRate = !heartRateOnly || workout.averageHeartRateBPM != nil
            let matchesDuration = workout.duration >= minimumDurationMinutes * 60
            let matchesDistance = (workout.totalDistanceMeters ?? 0) >= minimumDistanceMeters
            return matchesText && matchesActivity && matchesSource && matchesDate
                && matchesRoute && matchesHeartRate && matchesDuration && matchesDistance
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

    func load(using client: any HealthKitClient, resetLimit: Bool = true) async {
        if resetLimit { requestedLimit = 50 }
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

    func loadMore(using client: any HealthKitClient) async {
        guard canLoadMore, state == .loaded else { return }
        requestedLimit += 50
        do {
            let loaded = try await client.fetchWorkouts(limit: requestedLimit)
            workouts = loaded
            canLoadMore = loaded.count == requestedLimit
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func resetFilters() {
        selectedActivity = "All"
        selectedSource = "All"
        dateRange = .all
        sortOrder = .newestFirst
        routeOnly = false
        heartRateOnly = false
        minimumDurationMinutes = 0
        minimumDistanceMeters = 0
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
}
