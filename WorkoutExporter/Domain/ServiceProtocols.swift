import Foundation

protocol HealthKitClient: Sendable {
    var isHealthDataAvailable: Bool { get }
    func requestReadAuthorization() async throws
    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary]
    func fetchWorkoutRoutePreview(id: UUID) async throws -> WorkoutRoutePreview?
    func fetchWorkoutDetail(id: UUID, settings: MetricCalculationSettings) async throws -> WorkoutDetail
}

protocol WorkoutRepository: Sendable {
    func workouts(limit: Int) async throws -> [WorkoutSummary]
    func workoutDetail(id: UUID, settings: MetricCalculationSettings) async throws -> WorkoutDetail
}

protocol WorkoutRouteRepository: Sendable {
    func routePoints(workoutID: UUID) async throws -> [UUID: [RoutePoint]]
}

extension HealthKitClient {
    func fetchWorkoutRoutePreview(id: UUID) async throws -> WorkoutRoutePreview? {
        nil
    }
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

struct WorkoutExportRequest: Sendable {
    let id: UUID
    let load: @Sendable () async throws -> WorkoutDetail

    static func loaded(_ detail: WorkoutDetail) -> WorkoutExportRequest {
        WorkoutExportRequest(id: detail.id) { detail }
    }
}

struct ExportPackageResult: Sendable {
    let url: URL
    let exportedWorkoutIDs: Set<UUID>
}

protocol ExportPackageBuilding: Sendable {
    func buildPackageResult(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> ExportPackageResult
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
    func buildPackageResult(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL
    ) async throws -> ExportPackageResult {
        try await buildPackageResult(
            for: requests,
            options: options,
            to: directory
        ) { _ in }
    }

    func buildPackage(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL
    ) async throws -> URL {
        try await buildPackageResult(
            for: requests,
            options: options,
            to: directory
        ).url
    }

    func buildPackage(
        for requests: [WorkoutExportRequest],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> URL {
        try await buildPackageResult(
            for: requests,
            options: options,
            to: directory,
            progress: progress
        ).url
    }

    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL,
        progress: @escaping @Sendable (ExportProgress) async -> Void
    ) async throws -> URL {
        try await buildPackageResult(
            for: workouts.map(WorkoutExportRequest.loaded),
            options: options,
            to: directory,
            progress: progress
        ).url
    }

    func buildPackage(
        for workouts: [WorkoutDetail],
        options: ExportOptions,
        to directory: URL
    ) async throws -> URL {
        try await buildPackage(for: workouts, options: options, to: directory) { _ in }
    }
}
