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

        let altitudes = groups.flatMap { $0.map(\.altitudeMeters) }.filter(\.isFinite)
        let rawElevation = elevationChange(altitudes, noiseThreshold: 0)
        let smoothedAltitudes = movingAverage(altitudes, window: settings.elevationSmoothingWindow)
        let smoothElevation = elevationChange(
            smoothedAltitudes,
            noiseThreshold: settings.elevationNoiseThresholdMeters
        )

        let heartRates = detail.heartRateSamples.map(\.value).filter { $0.isFinite && $0 > 0 }
        if groups.isEmpty { warnings.append("No route was available; route-derived metrics are omitted.") }
        if heartRates.isEmpty { warnings.append("No heart-rate samples were accessible.") }

        return DerivedMetrics(
            routeDistanceMeters: groups.isEmpty ? nil : metric(distance, unit: "m", .routeDerived),
            eventAwareMovingTime: metric(eventMoving, unit: "s", .routeDerived),
            speedThresholdMovingTime: groups.isEmpty ? nil : metric(elapsedMoving, unit: "s", .routeDerived),
            averageSpeedMetersPerSecond: averageSpeed.map { metric($0, unit: "m/s", .routeDerived) },
            maximumSpeedMetersPerSecond: maximumSpeed.map { metric($0, unit: "m/s", .routeDerived) },
            rawElevationGainMeters: altitudes.isEmpty ? nil : metric(rawElevation.gain, unit: "m", .routeDerived),
            smoothedElevationGainMeters: altitudes.isEmpty ? nil : metric(smoothElevation.gain, unit: "m", .smoothedRouteDerived),
            elevationLossMeters: altitudes.isEmpty ? nil : metric(smoothElevation.loss, unit: "m", .smoothedRouteDerived),
            minimumAltitudeMeters: altitudes.min().map { metric($0, unit: "m", .location) },
            maximumAltitudeMeters: altitudes.max().map { metric($0, unit: "m", .location) },
            averageHeartRateBPM: heartRates.isEmpty ? nil : metric(heartRates.reduce(0, +) / Double(heartRates.count), unit: "count/min", .healthKitSample),
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

    private func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 2 else { return values }
        let radius = max(1, window / 2)
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private func elevationChange(_ altitudes: [Double], noiseThreshold: Double) -> (gain: Double, loss: Double) {
        guard altitudes.count > 1 else { return (0, 0) }
        return zip(altitudes, altitudes.dropFirst()).reduce(into: (gain: 0.0, loss: 0.0)) { result, pair in
            let delta = pair.1 - pair.0
            guard abs(delta) >= noiseThreshold else { return }
            if delta > 0 { result.gain += delta } else { result.loss += -delta }
        }
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
            let altitude = elevationChange(splitSegments.flatMap { [$0.start.altitudeMeters, $0.end.altitudeMeters] }, noiseThreshold: 3)
            output.append(WorkoutSplit(
                index: output.count + 1,
                startDate: startDate,
                endDate: endDate,
                distanceMeters: distance,
                elapsedTime: elapsed,
                movingTime: moving,
                paceSecondsPerKilometer: distance > 0 ? elapsed / (distance / 1_000) : nil,
                speedMetersPerSecond: moving > 0 ? distance / moving : nil,
                elevationGainMeters: altitude.gain,
                elevationLossMeters: altitude.loss,
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
