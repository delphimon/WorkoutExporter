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
    var chartPresentation: WorkoutChartPresentation?

    func load(
        id: UUID,
        client: any HealthKitClient,
        settings: MetricCalculationSettings
    ) async {
        state = .loading
        chartPresentation = nil
        do {
            let detail = try await client.fetchWorkoutDetail(
                id: id,
                settings: settings
            )
            state = .loaded(detail)
            let presentation = await Task.detached(priority: .userInitiated) {
                WorkoutChartPresentation(detail: detail)
            }.value
            guard case .loaded(let currentDetail) = state,
                  currentDetail.id == detail.id else {
                return
            }
            chartPresentation = presentation
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
