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
        referenceDate: Date,
        client: any HealthKitClient,
        settings: MetricCalculationSettings
    ) async {
        state = .loading
        chartPresentation = nil
        do {
            var effectiveSettings = settings
            let zoneSettings = settings.heartRateZones
            if zoneSettings.method != .manual,
               zoneSettings.automaticallyEstimateMaximumHeartRate,
               let dateOfBirth = try? await client.fetchDateOfBirthComponents(),
               let estimate = AgeBasedMaximumHeartRateEstimate(
                   dateOfBirthComponents: dateOfBirth,
                   asOf: referenceDate
                ) {
                effectiveSettings.heartRateZones.maximumHeartRateBPM =
                    estimate.maximumHeartRateBPM.rounded()
            }
            let detail = try await client.fetchWorkoutDetail(
                id: id,
                settings: effectiveSettings
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
