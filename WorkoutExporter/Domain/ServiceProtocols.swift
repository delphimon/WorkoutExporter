import Foundation

protocol HealthKitClient: Sendable {
    var isHealthDataAvailable: Bool { get }
    func requestReadAuthorization() async throws
    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary]
    func fetchWorkoutDetail(id: UUID, settings: MetricCalculationSettings) async throws -> WorkoutDetail
}

protocol WorkoutRepository: Sendable {
    func workouts(limit: Int) async throws -> [WorkoutSummary]
    func workoutDetail(id: UUID, settings: MetricCalculationSettings) async throws -> WorkoutDetail
}

protocol WorkoutRouteRepository: Sendable {
    func routePoints(workoutID: UUID) async throws -> [UUID: [RoutePoint]]
}

protocol WorkoutMetricCalculating: Sendable {
    func calculate(detail: WorkoutDetail) async throws -> DerivedMetrics
}

protocol WorkoutExporting: Sendable {
    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress.Phase) async -> Void
    ) async throws -> [URL]
}

protocol ExportPackageBuilding: Sendable {
    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> URL
}

extension WorkoutExporting {
    func export(
        _ detail: WorkoutDetail,
        formats: Set<ExportFormat>,
        to directory: URL
    ) async throws -> [URL] {
        try await export(detail, formats: formats, to: directory) { _ in }
    }
}

extension ExportPackageBuilding {
    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL
    ) async throws -> URL {
        try await buildPackage(for: workouts, options: options, to: directory) { _ in }
    }
}
