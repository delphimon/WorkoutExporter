import Foundation
import Observation

@MainActor
@Observable
final class WorkoutListViewModel {
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
    var routeOnly = false
    var minimumDurationMinutes = 0.0
    var selectedIDs: Set<UUID> = []
    var isSelecting = false

    var activityOptions: [String] {
        ["All"] + Set(workouts.map(\.activityName)).sorted()
    }

    var filteredWorkouts: [WorkoutSummary] {
        workouts.filter { workout in
            let matchesText = searchText.isEmpty
                || workout.activityName.localizedCaseInsensitiveContains(searchText)
                || workout.source.name.localizedCaseInsensitiveContains(searchText)
            let matchesActivity = selectedActivity == "All" || workout.activityName == selectedActivity
            let matchesRoute = !routeOnly || workout.hasRoute
            let matchesDuration = workout.duration >= minimumDurationMinutes * 60
            return matchesText && matchesActivity && matchesRoute && matchesDuration
        }
    }

    func load(using client: any HealthKitClient) async {
        state = .loading
        do {
            workouts = try await client.fetchWorkouts(limit: 200)
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
}
