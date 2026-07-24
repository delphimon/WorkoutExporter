import Foundation
import Observation

@MainActor
@Observable
final class WorkoutDetailViewModel {
    enum State {
        case loading
        case loaded(WorkoutDetail)
        case failed(String)
    }

    var state: State = .loading

    func load(
        id: UUID,
        client: any HealthKitClient,
        settings: MetricCalculationSettings
    ) async {
        state = .loading
        do {
            state = .loaded(try await client.fetchWorkoutDetail(id: id, settings: settings))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
