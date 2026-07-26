import CoreLocation
import Foundation

struct WorkoutMetricCalculator: WorkoutMetricCalculating {
    func calculate(detail: WorkoutDetail) async throws -> DerivedMetrics {
        try Task.checkCancellation()
        let settings = detail.metricSettings
        let groups = detail.routes.values
            .map { $0.sorted { $0.sequence < $1.sequence } }
            .sorted { ($0.first?.timestamp ?? .distantFuture) < ($1.first?.timestamp ?? .distantFuture) }
        var allSegments: [RouteSegment] = []
        var routeMetrics: [RouteMetricPoint] = []
        var cumulativeDistance = 0.0

        for points in groups {
            try Task.checkCancellation()
            let segments = routeSegments(points: points, settings: settings)
            allSegments.append(contentsOf: segments)
            let result = metricPoints(
                points: points,
                segments: segments,
                startingDistance: cumulativeDistance
            )
            routeMetrics.append(contentsOf: result.points)
            cumulativeDistance = result.cumulativeDistance
        }

        let validSegments = allSegments.filter(\.isValid)
        var warnings = allSegments.compactMap(\.warning)
        let distance = validSegments.reduce(0) { $0 + $1.distance }
        let thresholdMoving = speedThresholdMovingTime(segments: validSegments, settings: settings)
        let eventMoving = eventAwareMovingTime(detail: detail)
        let averageSpeed = thresholdMoving > 0 ? distance / thresholdMoving : nil
        let recordedMaximumSpeed = groups
            .flatMap { $0.compactMap(\.speedMetersPerSecond) }
            .filter { $0.isFinite && $0 >= 0 }
            .max()
        let nativeAverageSpeed = nativeStatistic(in: detail, matching: "Speed", aggregation: "average")
        let nativeMaximumSpeed = nativeStatistic(in: detail, matching: "Speed", aggregation: "maximum")
        let altitudes = groups.flatMap { $0.map(\.altitudeMeters) }.filter(\.isFinite)
        let heartRates = detail.heartRateSamples.map(\.value).filter { $0.isFinite && $0 > 0 }
        let elevation = elevationMetrics(segments: validSegments)

        if groups.isEmpty {
            warnings.append("No route was available; route-derived metrics are omitted.")
        }
        if heartRates.isEmpty {
            warnings.append("No heart-rate samples were accessible.")
        }

        return DerivedMetrics(
            routeDistanceMeters: groups.isEmpty ? nil : metric(distance, unit: "m", .routeDerived),
            eventAwareMovingTime: metric(eventMoving, unit: "s", .routeDerived),
            speedThresholdMovingTime: groups.isEmpty ? nil : metric(thresholdMoving, unit: "s", .routeDerived),
            averageSpeedMetersPerSecond: nativeAverageSpeed.map { metric($0, unit: "m/s", .healthKitStatistic) }
                ?? averageSpeed.map { metric($0, unit: "m/s", .routeDerived) },
            maximumSpeedMetersPerSecond: nativeMaximumSpeed.map { metric($0, unit: "m/s", .healthKitStatistic) }
                ?? recordedMaximumSpeed.map { metric($0, unit: "m/s", .location) },
            rawElevationGainMeters: detail.summary.elevationGainMeters.map {
                metric($0, unit: "m", .healthKitStatistic)
            },
            elevationLossMeters: groups.isEmpty ? nil : metric(
                elevation.loss, unit: "m", .routeDerived
            ),
            minimumAltitudeMeters: altitudes.min().map { metric($0, unit: "m", .location) },
            maximumAltitudeMeters: altitudes.max().map { metric($0, unit: "m", .location) },
            averageHeartRateBPM: detail.summary.averageHeartRateBPM.map {
                metric($0, unit: "count/min", .healthKitStatistic)
            } ?? average(heartRates).map { metric($0, unit: "count/min", .healthKitSample) },
            minimumHeartRateBPM: heartRates.min().map { metric($0, unit: "count/min", .healthKitSample) },
            maximumHeartRateBPM: heartRates.max().map { metric($0, unit: "count/min", .healthKitSample) },
            routeMetrics: routeMetrics,
            heartRateZones: makeHeartRateZones(
                samples: detail.heartRateSamples,
                settings: settings.heartRateZones
            ),
            splits: makeSplits(
                segments: validSegments,
                heartRates: detail.heartRateSamples,
                settings: settings
            ),
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private func metric(_ value: Double, unit: String, _ provenance: DataProvenance) -> MetricValue {
        MetricValue(value: value, unit: unit, provenance: provenance)
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
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
                return RouteSegment(
                    start: start, end: end, distance: 0, duration: duration, speed: 0,
                    isValid: false, warning: "Ignored a route point with a non-increasing timestamp."
                )
            }
            guard duration <= settings.maximumRouteGap else {
                return RouteSegment(
                    start: start, end: end, distance: distance, duration: duration, speed: 0,
                    isValid: false,
                    warning: "A route gap longer than \(Int(settings.maximumRouteGap)) seconds was not bridged."
                )
            }
            guard start.horizontalAccuracyMeters >= 0,
                  end.horizontalAccuracyMeters >= 0,
                  start.horizontalAccuracyMeters <= settings.maximumHorizontalAccuracyMeters,
                  end.horizontalAccuracyMeters <= settings.maximumHorizontalAccuracyMeters else {
                return RouteSegment(
                    start: start, end: end, distance: distance, duration: duration, speed: 0,
                    isValid: false,
                    warning: "Low-accuracy route points were preserved but excluded from derived metrics."
                )
            }
            let speed = distance / duration
            guard speed <= settings.maximumPlausibleSpeedMetersPerSecond else {
                return RouteSegment(
                    start: start, end: end, distance: distance, duration: duration, speed: speed,
                    isValid: false,
                    warning: "An implausible GPS jump was preserved but excluded from derived metrics."
                )
            }
            return RouteSegment(
                start: start, end: end, distance: distance, duration: duration, speed: speed,
                isValid: true, warning: nil
            )
        }
    }

    private func metricPoints(
        points: [RoutePoint],
        segments: [RouteSegment],
        startingDistance: Double
    ) -> (points: [RouteMetricPoint], cumulativeDistance: Double) {
        guard let first = points.first else { return ([], startingDistance) }
        var cumulative = startingDistance
        var output = [
            RouteMetricPoint(
                routePointID: first.id,
                routeID: first.routeID,
                sequence: first.sequence,
                timestamp: first.timestamp,
                segmentDistanceMeters: 0,
                cumulativeDistanceMeters: cumulative,
                derivedSpeedMetersPerSecond: nil,
                rawPaceSecondsPerKilometer: nil,
                grade: nil,
                verticalSpeedMetersPerSecond: nil,
                provenance: .routeDerived
            )
        ]

        for segment in segments {
            let distance = segment.isValid ? segment.distance : 0
            cumulative += distance
            let speed = segment.isValid ? segment.speed : nil
            let altitudeDelta = segment.end.altitudeMeters - segment.start.altitudeMeters
            output.append(
                RouteMetricPoint(
                    routePointID: segment.end.id,
                    routeID: segment.end.routeID,
                    sequence: segment.end.sequence,
                    timestamp: segment.end.timestamp,
                    segmentDistanceMeters: distance,
                    cumulativeDistanceMeters: cumulative,
                    derivedSpeedMetersPerSecond: speed,
                    rawPaceSecondsPerKilometer: speed.flatMap {
                        $0 > 0 ? 1_000 / $0 : nil
                    },
                    grade: segment.isValid && segment.distance > 0 ? altitudeDelta / segment.distance : nil,
                    verticalSpeedMetersPerSecond: segment.isValid && segment.duration > 0
                        ? altitudeDelta / segment.duration
                        : nil,
                    provenance: .routeDerived
                )
            )
        }

        return (output, cumulative)
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

    private func speedThresholdMovingTime(
        segments: [RouteSegment],
        settings: MetricCalculationSettings
    ) -> TimeInterval {
        guard !segments.isEmpty else { return 0 }
        var runs: [(moving: Bool, duration: TimeInterval)] = []
        for segment in segments {
            let isMoving = segment.speed >= settings.movingSpeedThresholdMetersPerSecond
            if let last = runs.last, last.moving == isMoving {
                runs[runs.count - 1].duration += segment.duration
            } else {
                runs.append((isMoving, segment.duration))
            }
        }
        return runs.reduce(0) { result, run in
            if run.moving, run.duration >= settings.minimumMovingDuration {
                return result + run.duration
            }
            if !run.moving, run.duration < settings.minimumStoppedDuration {
                return result + run.duration
            }
            return result
        }
    }

    private func elevationMetrics(segments: [RouteSegment]) -> (gain: Double, loss: Double) {
        var gain = 0.0
        var loss = 0.0
        for segment in segments {
            let delta = segment.end.altitudeMeters - segment.start.altitudeMeters
            if delta > 0 {
                gain += delta
            } else {
                loss += -delta
            }
        }
        return (gain, loss)
    }

    private func makeHeartRateZones(
        samples: [WorkoutSample],
        settings: HeartRateZoneSettings
    ) -> [HeartRateZoneResult] {
        let ordered = samples.sorted { $0.startDate < $1.startDate }
        guard !ordered.isEmpty else { return [] }
        let calculatedUpperBounds: [Double]
        switch settings.method {
        case .manual:
            calculatedUpperBounds = settings.manualUpperBoundsBPM.sorted()
        case .percentMaximum:
            calculatedUpperBounds = [0.6, 0.7, 0.8, 0.9].map {
                settings.maximumHeartRateBPM * $0
            }
        case .heartRateReserve:
            let reserve = max(0, settings.maximumHeartRateBPM - settings.restingHeartRateBPM)
            calculatedUpperBounds = [0.6, 0.7, 0.8, 0.9].map {
                settings.restingHeartRateBPM + reserve * $0
            }
        }
        let upperBounds = calculatedUpperBounds.map { $0.rounded() }
        var durations = Array(repeating: 0.0, count: upperBounds.count + 1)
        for index in ordered.indices {
            let sample = ordered[index]
            let explicitDuration = sample.endDate.timeIntervalSince(sample.startDate)
            let inferredDuration = index < ordered.index(before: ordered.endIndex)
                ? ordered[index + 1].startDate.timeIntervalSince(sample.startDate)
                : 0
            let duration = max(0, explicitDuration > 0 ? explicitDuration : min(inferredDuration, 30))
            let zone = upperBounds.firstIndex { sample.value < $0 } ?? upperBounds.count
            durations[zone] += duration
        }
        return durations.indices.map { index in
            HeartRateZoneResult(
                zone: index + 1,
                lowerBoundBPM: index == 0 ? 0 : upperBounds[index - 1],
                upperBoundBPM: index < upperBounds.count ? upperBounds[index] : nil,
                duration: durations[index]
            )
        }
    }

    private func makeSplits(
        segments: [RouteSegment],
        heartRates: [WorkoutSample],
        settings: MetricCalculationSettings
    ) -> [WorkoutSplit] {
        guard let first = segments.first else { return [] }
        var output: [WorkoutSplit] = []
        var splitSegments: [RouteSegment] = []
        var accumulatedDistance = 0.0
        var startDate = first.start.timestamp

        func appendSplit(ending endDate: Date) {
            guard let start = splitSegments.first?.start, let end = splitSegments.last?.end else { return }
            let distance = splitSegments.reduce(0) { $0 + $1.distance }
            let elapsed = max(0, endDate.timeIntervalSince(startDate))
            let moving = speedThresholdMovingTime(segments: splitSegments, settings: settings)
            let samples = heartRates.filter { $0.startDate >= startDate && $0.startDate <= endDate }
            let values = samples.map(\.value)
            let elevation = elevationMetrics(segments: splitSegments)
            output.append(
                WorkoutSplit(
                    index: output.count + 1,
                    startDate: startDate,
                    endDate: endDate,
                    distanceMeters: distance,
                    elapsedTime: elapsed,
                    movingTime: moving,
                    paceSecondsPerKilometer: distance > 0 ? elapsed / (distance / 1_000) : nil,
                    speedMetersPerSecond: moving > 0 ? distance / moving : nil,
                    elevationGainMeters: elevation.gain,
                    elevationLossMeters: elevation.loss,
                    averageHeartRateBPM: average(values),
                    maximumHeartRateBPM: values.max(),
                    startLatitude: start.latitude,
                    startLongitude: start.longitude,
                    endLatitude: end.latitude,
                    endLongitude: end.longitude
                )
            )
        }

        for segment in segments {
            splitSegments.append(segment)
            accumulatedDistance += segment.distance
            let elapsed = segment.end.timestamp.timeIntervalSince(startDate)
            let reachedBoundary = switch settings.splitMode {
            case .distance: accumulatedDistance >= settings.splitDistanceMeters
            case .elapsedTime: elapsed >= settings.splitElapsedTime
            }
            if reachedBoundary {
                appendSplit(ending: segment.end.timestamp)
                splitSegments.removeAll(keepingCapacity: true)
                accumulatedDistance = 0
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
    var duration: Double
    var speed: Double
    var isValid: Bool
    var warning: String?
}
