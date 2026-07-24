import Foundation

#if DEBUG
enum SyntheticWorkoutScenario: String, CaseIterable, Sendable {
    case cleanOutdoorRun
    case hikeWithStops
    case walkWithAutoPause
    case noRoute
    case noHeartRate
    case multipleRouteSegments
    case poorGPS
    case implausibleGPSJump
    case timeZoneBoundary
    case crossingMidnight
    case multisport
    case veryLongWorkout
    case intervalHeartRate
    case conflictingDistance
    case partialQueryFailures
}

actor SyntheticHealthKitClient: HealthKitClient {
    nonisolated let isHealthDataAvailable = true
    private let details: [UUID: WorkoutDetail]
    private let metricCalculator: WorkoutMetricCalculating

    init(metricCalculator: WorkoutMetricCalculating = WorkoutMetricCalculator()) {
        self.metricCalculator = metricCalculator
        let workouts = SyntheticWorkoutFactory.makeAll()
        details = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        details.values
            .map(\.summary)
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        guard var detail = details[id] else { throw WorkoutExporterError.noAccessibleData }
        detail.metricSettings = settings
        detail.derived = try await metricCalculator.calculate(detail: detail)
        detail.warnings.append(contentsOf: detail.derived.warnings)
        return detail
    }
}

enum SyntheticWorkoutFactory {
    static func makeAll() -> [WorkoutDetail] {
        SyntheticWorkoutScenario.allCases.enumerated().map { index, scenario in
            make(scenario, index: index)
        }
    }

    static func make(_ scenario: SyntheticWorkoutScenario, index: Int = 0) -> WorkoutDetail {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 7,
            day: 20,
            hour: 7
        ))!
        let start = base.addingTimeInterval(TimeInterval(-index * 86_400))
        let duration: TimeInterval = scenario == .veryLongWorkout ? 21_600 : 3_600
        let end = start.addingTimeInterval(duration)
        let id = stableUUID(index + 1)
        let activityName: String
        let activityIdentifier: UInt
        switch scenario {
        case .hikeWithStops: (activityName, activityIdentifier) = ("Hiking", 52)
        case .walkWithAutoPause: (activityName, activityIdentifier) = ("Walking", 52)
        case .multisport: (activityName, activityIdentifier) = ("Multisport", 82)
        default: (activityName, activityIdentifier) = ("Running", 37)
        }

        let source = SourceInfo(
            name: "Synthetic Apple Watch",
            bundleIdentifier: "com.delphimon.WorkoutExporter.synthetic",
            version: "1",
            operatingSystemVersion: "26.0"
        )
        let device = DeviceInfo(
            name: "Apple Watch (Synthetic)",
            manufacturer: "Apple Inc.",
            model: "Synthetic",
            hardwareVersion: nil,
            softwareVersion: "26.0",
            localIdentifier: nil,
            firmwareVersion: nil
        )

        var routeCount = scenario == .veryLongWorkout ? 10_000 : 240
        if [.noRoute].contains(scenario) { routeCount = 0 }
        var route = makeRoute(
            id: stableUUID(index + 100),
            start: start,
            count: routeCount,
            interval: duration / Double(max(routeCount, 1)),
            hiking: scenario == .hikeWithStops
        )
        if scenario == .poorGPS {
            for pointIndex in route.indices where pointIndex.isMultiple(of: 10) {
                route[pointIndex].horizontalAccuracyMeters = 125
                route[pointIndex].qualityFlags = ["lowHorizontalAccuracy"]
            }
        }
        if scenario == .implausibleGPSJump, route.count > 100 {
            route[100].latitude += 1
            route[100].longitude += 1
            route[100].qualityFlags = ["implausibleJumpCandidate"]
        }
        if scenario == .hikeWithStops, route.count > 100 {
            for pointIndex in 80..<100 {
                route[pointIndex].latitude = route[79].latitude
                route[pointIndex].longitude = route[79].longitude
            }
        }

        let heartRate = scenario == .noHeartRate ? [] : makeHeartRate(
            start: start,
            duration: duration,
            source: source,
            device: device,
            intervalValued: scenario == .intervalHeartRate
        )
        let events: [WorkoutEvent] = [.walkWithAutoPause, .hikeWithStops].contains(scenario)
            ? [
                WorkoutEvent(id: UUID(), kind: .pause, startDate: start.addingTimeInterval(1_200), endDate: nil, metadata: ["synthetic": "true"]),
                WorkoutEvent(id: UUID(), kind: .resume, startDate: start.addingTimeInterval(1_320), endDate: nil, metadata: ["synthetic": "true"])
            ]
            : []

        var routes: [UUID: [RoutePoint]] = [:]
        if !route.isEmpty {
            if scenario == .multipleRouteSegments {
                let midpoint = route.count / 2
                let secondID = stableUUID(index + 200)
                routes[route[0].routeID] = Array(route[..<midpoint])
                routes[secondID] = route[midpoint...].enumerated().map { sequence, point in
                    var copy = point
                    copy.routeID = secondID
                    copy.sequence = sequence
                    return copy
                }
            } else {
                routes[route[0].routeID] = route
            }
        }

        let routeDistance = Double(max(routeCount - 1, 0)) * 12
        let healthDistance = scenario == .conflictingDistance ? routeDistance * 1.15 : routeDistance
        let summary = WorkoutSummary(
            id: id,
            activityIdentifier: activityIdentifier,
            activityName: activityName,
            startDate: start,
            endDate: end,
            duration: duration,
            totalDistanceMeters: route.isEmpty ? nil : healthDistance,
            elevationGainMeters: route.isEmpty ? nil : (scenario == .hikeWithStops ? 420 : 35),
            activeEnergyKilocalories: 540,
            averageHeartRateBPM: heartRate.isEmpty ? nil : 146,
            source: source,
            device: device,
            hasRoute: !route.isEmpty,
            hasDetailedSamples: !heartRate.isEmpty
        )
        let activities = scenario == .multisport
            ? [
                WorkoutActivitySegment(id: UUID(), activityIdentifier: 37, activityName: "Running", startDate: start, endDate: start.addingTimeInterval(duration / 2), metadata: [:]),
                WorkoutActivitySegment(id: UUID(), activityIdentifier: 13, activityName: "Cycling", startDate: start.addingTimeInterval(duration / 2), endDate: end, metadata: [:])
            ]
            : []
        var warnings: [String] = []
        if scenario == .partialQueryFailures {
            warnings.append("Synthetic fixture: cadence query failed; other data remains available.")
        }
        if scenario == .timeZoneBoundary {
            warnings.append("Synthetic fixture includes an explicit time-zone-context change.")
        }
        if scenario == .crossingMidnight {
            warnings.append("Synthetic fixture crosses local midnight.")
        }
        return WorkoutDetail(
            summary: summary,
            events: events,
            activities: activities,
            statistics: [
                NativeStatistic(typeIdentifier: "HKQuantityTypeIdentifierDistanceWalkingRunning", aggregation: "sum", value: healthDistance, unit: "m"),
                NativeStatistic(typeIdentifier: "HKMetadataKeyElevationAscended", aggregation: "metadata", value: scenario == .hikeWithStops ? 420 : 35, unit: "m"),
                NativeStatistic(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", aggregation: "average", value: 146, unit: "count/min")
            ],
            samples: heartRate,
            categorySamples: [],
            routes: routes,
            metadata: ["fixture": scenario.rawValue],
            derived: .empty,
            metricSettings: .conservativeDefault,
            warnings: warnings
        )
    }

    private static func makeRoute(
        id: UUID,
        start: Date,
        count: Int,
        interval: TimeInterval,
        hiking: Bool
    ) -> [RoutePoint] {
        (0..<count).map { index in
            let angle = Double(index) / 50
            let altitude = 20 + sin(angle) * (hiking ? 45 : 5) + Double(index) * (hiking ? 0.08 : 0.005)
            return RoutePoint(
                id: UUID(),
                routeID: id,
                sequence: index,
                timestamp: start.addingTimeInterval(Double(index) * interval),
                latitude: 37.7749 + Double(index) * 0.00009,
                longitude: -122.4194 + sin(angle) * 0.0002,
                altitudeMeters: altitude,
                ellipsoidalAltitudeMeters: altitude + 31,
                horizontalAccuracyMeters: 5,
                verticalAccuracyMeters: 7,
                speedMetersPerSecond: 3,
                speedAccuracyMetersPerSecond: 0.4,
                courseDegrees: 18,
                courseAccuracyDegrees: 4,
                floor: nil,
                qualityFlags: []
            )
        }
    }

    private static func makeHeartRate(
        start: Date,
        duration: TimeInterval,
        source: SourceInfo,
        device: DeviceInfo,
        intervalValued: Bool
    ) -> [WorkoutSample] {
        let count = Int(duration / 5)
        return (0..<count).map { index in
            let sampleStart = start.addingTimeInterval(Double(index) * 5)
            return WorkoutSample(
                id: UUID(),
                typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
                startDate: sampleStart,
                endDate: sampleStart.addingTimeInterval(intervalValued ? 4 : 0),
                value: 140 + sin(Double(index) / 20) * 18,
                unit: "count/min",
                source: source,
                device: device,
                provenance: .healthKitSample,
                metadata: intervalValued ? ["sampleSemantics": "interval"] : [:]
            )
        }
    }

    private static func stableUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
#endif
