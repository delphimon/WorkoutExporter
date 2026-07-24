import CoreLocation
import Foundation

struct WorkoutMetricCalculator: WorkoutMetricCalculating {
    func calculate(detail: WorkoutDetail) async throws -> DerivedMetrics {
        try Task.checkCancellation()
        let settings = detail.metricSettings
        let groups = detail.routes.values.map { $0.sorted { $0.sequence < $1.sequence } }
        let segments = groups.flatMap { routeSegments(points: $0, settings: settings) }
        let validSegments = segments.filter(\.isValid)
        var warnings = segments.compactMap(\.warning)

        let distance = validSegments.reduce(0) { $0 + $1.distance }
        let elapsedMoving = validSegments
            .filter { $0.speed >= settings.movingSpeedThresholdMetersPerSecond }
            .reduce(0) { $0 + $1.duration }
        let eventMoving = eventAwareMovingTime(detail: detail)
        let averageSpeed = elapsedMoving > 0 ? distance / elapsedMoving : nil
        let maximumSpeed = validSegments.map(\.speed).max()
        let nativeAverageSpeed = nativeStatistic(in: detail, matching: "Speed", aggregation: "average")
        let nativeMaximumSpeed = nativeStatistic(in: detail, matching: "Speed", aggregation: "maximum")

        let altitudes = groups.flatMap { $0.map(\.altitudeMeters) }.filter(\.isFinite)
        let heartRates = detail.heartRateSamples.map(\.value).filter { $0.isFinite && $0 > 0 }
        if groups.isEmpty { warnings.append("No route was available; route-derived metrics are omitted.") }
        if heartRates.isEmpty { warnings.append("No heart-rate samples were accessible.") }

        return DerivedMetrics(
            routeDistanceMeters: groups.isEmpty ? nil : metric(distance, unit: "m", .routeDerived),
            eventAwareMovingTime: metric(eventMoving, unit: "s", .routeDerived),
            speedThresholdMovingTime: groups.isEmpty ? nil : metric(elapsedMoving, unit: "s", .routeDerived),
            averageSpeedMetersPerSecond: nativeAverageSpeed.map { metric($0, unit: "m/s", .healthKitStatistic) }
                ?? averageSpeed.map { metric($0, unit: "m/s", .routeDerived) },
            maximumSpeedMetersPerSecond: nativeMaximumSpeed.map { metric($0, unit: "m/s", .healthKitStatistic) }
                ?? maximumSpeed.map { metric($0, unit: "m/s", .routeDerived) },
            rawElevationGainMeters: detail.summary.elevationGainMeters.map { metric($0, unit: "m", .healthKitStatistic) },
            smoothedElevationGainMeters: nil,
            elevationLossMeters: nil,
            minimumAltitudeMeters: altitudes.min().map { metric($0, unit: "m", .location) },
            maximumAltitudeMeters: altitudes.max().map { metric($0, unit: "m", .location) },
            averageHeartRateBPM: detail.summary.averageHeartRateBPM.map { metric($0, unit: "count/min", .healthKitStatistic) },
            minimumHeartRateBPM: heartRates.min().map { metric($0, unit: "count/min", .healthKitSample) },
            maximumHeartRateBPM: heartRates.max().map { metric($0, unit: "count/min", .healthKitSample) },
            splits: makeSplits(
                segments: validSegments,
                heartRates: detail.heartRateSamples,
                splitDistance: settings.splitDistanceMeters,
                speedThreshold: settings.movingSpeedThresholdMetersPerSecond
            ),
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private func metric(_ value: Double, unit: String, _ provenance: DataProvenance) -> MetricValue {
        MetricValue(value: value, unit: unit, provenance: provenance)
    }

    private func nativeStatistic(
        in detail: WorkoutDetail,
        matching identifierFragment: String,
        aggregation: String
    ) -> Double? {
        detail.statistics.first {
            $0.typeIdentifier.localizedCaseInsensitiveContains(identifierFragment)
                && $0.aggregation == aggregation
        }?.value
    }

    private func routeSegments(
        points: [RoutePoint],
        settings: MetricCalculationSettings
    ) -> [RouteSegment] {
        zip(points, points.dropFirst()).map { start, end in
            let duration = end.timestamp.timeIntervalSince(start.timestamp)
            let first = CLLocation(latitude: start.latitude, longitude: start.longitude)
            let second = CLLocation(latitude: end.latitude, longitude: end.longitude)
            let distance = second.distance(from: first)

            guard duration > 0 else {
                return RouteSegment(start: start, end: end, distance: 0, duration: duration, speed: 0, isValid: false, warning: "Ignored a route point with a non-increasing timestamp.")
            }
            guard duration <= settings.maximumRouteGap else {
                return RouteSegment(start: start, end: end, distance: distance, duration: duration, speed: 0, isValid: false, warning: "A route gap longer than \(Int(settings.maximumRouteGap)) seconds was not bridged.")
            }
            guard start.horizontalAccuracyMeters >= 0,
                  end.horizontalAccuracyMeters >= 0,
                  start.horizontalAccuracyMeters <= settings.maximumHorizontalAccuracyMeters,
                  end.horizontalAccuracyMeters <= settings.maximumHorizontalAccuracyMeters else {
                return RouteSegment(start: start, end: end, distance: distance, duration: duration, speed: 0, isValid: false, warning: "Low-accuracy route points were preserved but excluded from derived metrics.")
            }
            let speed = distance / duration
            guard speed <= settings.maximumPlausibleSpeedMetersPerSecond else {
                return RouteSegment(start: start, end: end, distance: distance, duration: duration, speed: speed, isValid: false, warning: "An implausible GPS jump was preserved but excluded from derived metrics.")
            }
            return RouteSegment(start: start, end: end, distance: distance, duration: duration, speed: speed, isValid: true, warning: nil)
        }
    }

    private func eventAwareMovingTime(detail: WorkoutDetail) -> TimeInterval {
        let ordered = detail.events.sorted { $0.startDate < $1.startDate }
        var pausedAt: Date?
        var pausedDuration: TimeInterval = 0
        for event in ordered {
            switch event.kind {
            case .pause:
                pausedAt = pausedAt ?? event.startDate
            case .resume:
                if let pause = pausedAt {
                    pausedDuration += max(0, event.startDate.timeIntervalSince(pause))
                    pausedAt = nil
                }
            default:
                continue
            }
        }
        if let pause = pausedAt {
            pausedDuration += max(0, detail.summary.endDate.timeIntervalSince(pause))
        }
        return max(0, detail.summary.duration - pausedDuration)
    }

    private func makeSplits(
        segments: [RouteSegment],
        heartRates: [WorkoutSample],
        splitDistance: Double,
        speedThreshold: Double
    ) -> [WorkoutSplit] {
        guard splitDistance > 0, let first = segments.first else { return [] }
        var output: [WorkoutSplit] = []
        var splitSegments: [RouteSegment] = []
        var accumulated = 0.0
        var startDate = first.start.timestamp

        func appendSplit(ending endDate: Date) {
            guard let start = splitSegments.first?.start, let end = splitSegments.last?.end else { return }
            let distance = splitSegments.reduce(0) { $0 + $1.distance }
            let elapsed = max(0, endDate.timeIntervalSince(startDate))
            let moving = splitSegments.filter { $0.speed >= speedThreshold }.reduce(0) { $0 + $1.duration }
            let samples = heartRates.filter { $0.startDate >= startDate && $0.startDate <= endDate }
            let values = samples.map(\.value)
            output.append(WorkoutSplit(
                index: output.count + 1,
                startDate: startDate,
                endDate: endDate,
                distanceMeters: distance,
                elapsedTime: elapsed,
                movingTime: moving,
                paceSecondsPerKilometer: distance > 0 ? elapsed / (distance / 1_000) : nil,
                speedMetersPerSecond: moving > 0 ? distance / moving : nil,
                elevationGainMeters: nil,
                elevationLossMeters: nil,
                averageHeartRateBPM: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                maximumHeartRateBPM: values.max(),
                startLatitude: start.latitude,
                startLongitude: start.longitude,
                endLatitude: end.latitude,
                endLongitude: end.longitude
            ))
        }

        for segment in segments {
            splitSegments.append(segment)
            accumulated += segment.distance
            if accumulated >= splitDistance {
                appendSplit(ending: segment.end.timestamp)
                splitSegments.removeAll(keepingCapacity: true)
                accumulated = 0
                startDate = segment.end.timestamp
            }
        }
        if let last = splitSegments.last {
            appendSplit(ending: last.end.timestamp)
        }
        return output
    }
}

private struct RouteSegment {
    var start: RoutePoint
    var end: RoutePoint
    var distance: Double
    var duration: TimeInterval
    var speed: Double
    var isValid: Bool
    var warning: String?
}
