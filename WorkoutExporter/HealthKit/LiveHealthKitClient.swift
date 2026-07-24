import CoreLocation
import Foundation
import HealthKit

actor LiveHealthKitClient: HealthKitClient {
    private let healthStore: HKHealthStore
    private let metricCalculator: WorkoutMetricCalculating

    nonisolated var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        metricCalculator: WorkoutMetricCalculating = WorkoutMetricCalculator()
    ) {
        self.healthStore = healthStore
        self.metricCalculator = metricCalculator
    }

    func requestReadAuthorization() async throws {
        guard isHealthDataAvailable else { throw WorkoutExporterError.healthKitUnavailable }
        try await healthStore.requestAuthorization(toShare: [], read: HealthKitMappings.readTypes)
        // A successful request means only that the sheet completed. HealthKit intentionally
        // does not reveal whether read access was granted for each requested type.
    }

    func fetchWorkouts(limit: Int = 100) async throws -> [WorkoutSummary] {
        guard isHealthDataAvailable else { throw WorkoutExporterError.healthKitUnavailable }
        do {
            let descriptor = HKSampleQueryDescriptor<HKWorkout>(
                predicates: [.workout()],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                limit: limit
            )
            let workouts = try await descriptor.result(for: healthStore)
            guard !workouts.isEmpty else { throw WorkoutExporterError.noAccessibleData }
            var summaries: [WorkoutSummary] = []
            summaries.reserveCapacity(workouts.count)
            for workout in workouts {
                try Task.checkCancellation()
                summaries.append(try await summary(for: workout))
            }
            return summaries
        } catch let error as WorkoutExporterError {
            throw error
        } catch is CancellationError {
            throw WorkoutExporterError.cancelled
        } catch {
            throw WorkoutExporterError.queryFailure(error.localizedDescription)
        }
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        do {
            let predicate = HKQuery.predicateForObject(with: id)
            let descriptor = HKSampleQueryDescriptor<HKWorkout>(
                predicates: [.workout(predicate)],
                sortDescriptors: [],
                limit: 1
            )
            guard let workout = try await descriptor.result(for: healthStore).first else {
                throw WorkoutExporterError.noAccessibleData
            }

            let quantitySamples = try await fetchQuantitySamples(for: workout)
            let categories = try await fetchCategorySamples(for: workout)
            let (routes, routeWarnings) = await fetchRoutes(for: workout)
            let workoutSummary = try await summary(for: workout, knownRoutes: !routes.isEmpty)
            let events = (workout.workoutEvents ?? []).map {
                WorkoutEvent(
                    id: UUID(),
                    kind: HealthKitMappings.eventKind($0.type),
                    startDate: $0.dateInterval.start,
                    endDate: $0.dateInterval.duration > 0 ? $0.dateInterval.end : nil,
                    metadata: HealthKitMappings.safeMetadata($0.metadata)
                )
            }
            let activities = workout.workoutActivities.map {
                WorkoutActivitySegment(
                    id: $0.uuid,
                    activityIdentifier: $0.workoutConfiguration.activityType.rawValue,
                    activityName: HealthKitMappings.activityName($0.workoutConfiguration.activityType),
                    startDate: $0.startDate,
                    endDate: $0.endDate ?? workout.endDate,
                    metadata: HealthKitMappings.safeMetadata($0.metadata)
                )
            }
            var statistics = normalizedStatistics(workout.allStatistics)
            if let elevation = nativeElevationGain(for: workout) {
                statistics.append(NativeStatistic(
                    typeIdentifier: "HKMetadataKeyElevationAscended",
                    aggregation: "metadata",
                    value: elevation,
                    unit: "m"
                ))
            }
            var detail = WorkoutDetail(
                summary: workoutSummary,
                events: events,
                activities: activities,
                statistics: statistics,
                samples: quantitySamples,
                categorySamples: categories,
                routes: routes,
                metadata: HealthKitMappings.safeMetadata(workout.metadata),
                derived: .empty,
                metricSettings: settings,
                warnings: routeWarnings
            )
            detail.derived = try await metricCalculator.calculate(detail: detail)
            detail.warnings.append(contentsOf: detail.derived.warnings)
            return detail
        } catch let error as WorkoutExporterError {
            throw error
        } catch is CancellationError {
            throw WorkoutExporterError.cancelled
        } catch {
            throw WorkoutExporterError.queryFailure(error.localizedDescription)
        }
    }

    private func summary(for workout: HKWorkout, knownRoutes: Bool? = nil) async throws -> WorkoutSummary {
        let stats = workout.allStatistics
        let distance = stats.first { type, _ in
            type.identifier.localizedCaseInsensitiveContains("distance")
        }?.value.sumQuantity()?.doubleValue(for: .meter())
        let energyType = HKQuantityType(.activeEnergyBurned)
        let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let heartType = HKQuantityType(.heartRate)
        let heart = workout.statistics(for: heartType)?.averageQuantity()?
            .doubleValue(for: .count().unitDivided(by: .minute()))
        let hasRoute = if let knownRoutes {
            knownRoutes
        } else {
            try await routeSamples(for: workout, limit: 1).isEmpty == false
        }

        return WorkoutSummary(
            id: workout.uuid,
            activityIdentifier: workout.workoutActivityType.rawValue,
            activityName: HealthKitMappings.activityName(workout.workoutActivityType),
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalDistanceMeters: distance,
            elevationGainMeters: nativeElevationGain(for: workout),
            activeEnergyKilocalories: energy,
            averageHeartRateBPM: heart,
            source: HealthKitMappings.source(workout.sourceRevision),
            device: HealthKitMappings.device(workout.device),
            hasRoute: hasRoute,
            hasDetailedSamples: stats.isEmpty == false
        )
    }

    private func nativeElevationGain(for workout: HKWorkout) -> Double? {
        (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter())
    }

    private func fetchQuantitySamples(for workout: HKWorkout) async throws -> [WorkoutSample] {
        var output: [WorkoutSample] = []
        for entry in HealthKitMappings.quantityTypes {
            try Task.checkCancellation()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
                predicates: [.quantitySample(type: entry.type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let samples = try await descriptor.result(for: healthStore)
            output.append(contentsOf: samples.map {
                WorkoutSample(
                    id: $0.uuid,
                    typeIdentifier: entry.type.identifier,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    value: $0.quantity.doubleValue(for: entry.unit),
                    unit: entry.unit.unitString,
                    source: HealthKitMappings.source($0.sourceRevision),
                    device: HealthKitMappings.device($0.device),
                    provenance: .healthKitSample,
                    metadata: HealthKitMappings.safeMetadata($0.metadata)
                )
            })
        }
        return output.sorted { $0.startDate < $1.startDate }
    }

    private func fetchCategorySamples(for workout: HKWorkout) async throws -> [CategorySample] {
        var output: [CategorySample] = []
        for type in HealthKitMappings.categoryTypes {
            let predicate = HKQuery.predicateForObjects(from: workout)
            let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                predicates: [.categorySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let samples = try await descriptor.result(for: healthStore)
            output.append(contentsOf: samples.map {
                CategorySample(
                    id: $0.uuid,
                    typeIdentifier: type.identifier,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    value: $0.value,
                    source: HealthKitMappings.source($0.sourceRevision),
                    metadata: HealthKitMappings.safeMetadata($0.metadata)
                )
            })
        }
        return output
    }

    private func routeSamples(for workout: HKWorkout, limit: Int? = nil) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let descriptor = HKSampleQueryDescriptor<HKWorkoutRoute>(
            predicates: [.workoutRoute(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: limit
        )
        return try await descriptor.result(for: healthStore)
    }

    private func fetchRoutes(for workout: HKWorkout) async -> ([UUID: [RoutePoint]], [String]) {
        do {
            let samples = try await routeSamples(for: workout)
            var output: [UUID: [RoutePoint]] = [:]
            var warnings: [String] = []
            for route in samples {
                do {
                    var points: [RoutePoint] = []
                    var sequence = 0
                    for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
                        try Task.checkCancellation()
                        var flags: [String] = []
                        if location.horizontalAccuracy < 0 { flags.append("invalidHorizontalAccuracy") }
                        if location.horizontalAccuracy > 50 { flags.append("lowHorizontalAccuracy") }
                        if location.speed < 0 { flags.append("invalidNativeSpeed") }
                        points.append(RoutePoint(
                            id: UUID(),
                            routeID: route.uuid,
                            sequence: sequence,
                            timestamp: location.timestamp,
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            altitudeMeters: location.altitude,
                            ellipsoidalAltitudeMeters: location.ellipsoidalAltitude,
                            horizontalAccuracyMeters: location.horizontalAccuracy,
                            verticalAccuracyMeters: location.verticalAccuracy,
                            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
                            speedAccuracyMetersPerSecond: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
                            courseDegrees: location.course >= 0 ? location.course : nil,
                            courseAccuracyDegrees: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
                            floor: location.floor?.level,
                            qualityFlags: flags
                        ))
                        sequence += 1
                    }
                    output[route.uuid] = points.sorted {
                        $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp
                    }
                } catch {
                    warnings.append("Route \(route.uuid.uuidString) could not be fully read: \(error.localizedDescription)")
                }
            }
            return (output, warnings)
        } catch {
            return ([:], ["Workout routes could not be queried: \(error.localizedDescription)"])
        }
    }

    private func normalizedStatistics(
        _ statistics: [HKQuantityType: HKStatistics]
    ) -> [NativeStatistic] {
        statistics.flatMap { type, statistic -> [NativeStatistic] in
            let unit = HealthKitMappings.unit(for: type)
            let values: [(String, HKQuantity?)] = [
                ("sum", statistic.sumQuantity()),
                ("average", statistic.averageQuantity()),
                ("minimum", statistic.minimumQuantity()),
                ("maximum", statistic.maximumQuantity()),
                ("mostRecent", statistic.mostRecentQuantity())
            ]
            return values.compactMap { aggregation, quantity in
                quantity.map {
                    NativeStatistic(
                        typeIdentifier: type.identifier,
                        aggregation: aggregation,
                        value: $0.doubleValue(for: unit),
                        unit: unit.unitString
                    )
                }
            }
        }.sorted { $0.id < $1.id }
    }
}
