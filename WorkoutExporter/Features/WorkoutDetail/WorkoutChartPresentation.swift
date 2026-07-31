import Foundation

struct WorkoutChartPresentation: Sendable {
    static let chartPointLimit = 600
    static let mapPointLimit = 1_500
    static let minimumPaceWindowDuration: TimeInterval = 30

    let routePoints: [RoutePoint]
    let routeMetrics: [RouteMetricPoint]
    let heartRateSamples: [WorkoutSample]
    let pacePoints: [PaceChartPoint]
    let elevationPoints: [RoutePoint]
    let heartRateDomain: WorkoutChartDomain?
    let paceDomain: WorkoutChartDomain?
    let elevationDomain: WorkoutChartDomain?
    let mapRoutes: [MapRoutePresentation]
    let routeBounds: RouteBounds?
    private let paceSelectionPoints: [PaceChartPoint]

    init(detail: WorkoutDetail) {
        let sortedRoutePoints = detail.routes.values.flatMap { $0 }.sorted {
            if $0.timestamp == $1.timestamp {
                if $0.routeID == $1.routeID { return $0.sequence < $1.sequence }
                return $0.routeID.uuidString < $1.routeID.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
        let sortedRouteMetrics = (detail.derived.routeMetrics ?? []).sorted {
            $0.timestamp < $1.timestamp
        }
        let sortedHeartRate = detail.samples
            .filter {
                $0.typeIdentifier == "HKQuantityTypeIdentifierHeartRate"
                    && $0.startDate.timeIntervalSinceReferenceDate.isFinite
                    && $0.value.isFinite
            }
            .sorted { $0.startDate < $1.startDate }
        let validRoutePoints = sortedRoutePoints.filter(Self.isValidMapPoint)
        let validRouteMetrics = sortedRouteMetrics.filter {
            $0.timestamp.timeIntervalSinceReferenceDate.isFinite
                && $0.cumulativeDistanceMeters.isFinite
        }
        let allPacePoints = Self.paceChartPoints(
            metrics: sortedRouteMetrics,
            settings: detail.metricSettings
        )
        let routeCount = max(1, detail.routes.count)
        let perRouteLimit = max(2, Self.mapPointLimit / routeCount)
        let displayedHeartRate = Self.downsampleChart(
            sortedHeartRate,
            limit: Self.chartPointLimit,
            value: \.value
        )
        let displayedPace = Self.downsample(
            allPacePoints,
            limit: Self.chartPointLimit
        )
        let displayedElevation = Self.downsampleChart(
            validRoutePoints.filter {
                $0.altitudeMeters.isFinite
                    && $0.timestamp.timeIntervalSinceReferenceDate.isFinite
            },
            limit: Self.chartPointLimit,
            value: \.altitudeMeters
        )

        routePoints = validRoutePoints
        routeMetrics = validRouteMetrics
        heartRateSamples = displayedHeartRate
        pacePoints = displayedPace
        paceSelectionPoints = allPacePoints
        elevationPoints = displayedElevation
        heartRateDomain = WorkoutChartDomain(
            points: displayedHeartRate,
            date: \.startDate,
            value: \.value,
            minimumValuePadding: 1
        )
        paceDomain = WorkoutChartDomain(
            points: displayedPace,
            date: \.timestamp,
            value: \.paceSecondsPerKilometer,
            minimumValuePadding: 5
        )
        elevationDomain = WorkoutChartDomain(
            points: displayedElevation,
            date: \.timestamp,
            value: \.altitudeMeters,
            minimumValuePadding: 1
        )
        mapRoutes = detail.routes
            .compactMap { routeID, points in
                let sortedPoints = points.filter(Self.isValidMapPoint).sorted {
                    if $0.timestamp == $1.timestamp {
                        return $0.sequence < $1.sequence
                    }
                    return $0.timestamp < $1.timestamp
                }
                guard !sortedPoints.isEmpty else { return nil }
                return MapRoutePresentation(
                    id: routeID,
                    points: Self.downsample(
                        sortedPoints,
                        limit: perRouteLimit
                    )
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        routeBounds = RouteBounds(points: validRoutePoints)
    }

    func nearestRoutePoint(to date: Date) -> RoutePoint? {
        Self.nearest(in: routePoints, to: date, date: \.timestamp)
    }

    func nearestRouteMetric(to date: Date) -> RouteMetricPoint? {
        Self.nearest(in: routeMetrics, to: date, date: \.timestamp)
    }

    func nearestHeartRateSample(to date: Date) -> WorkoutSample? {
        Self.nearest(in: heartRateSamples, to: date, date: \.startDate)
    }

    func nearestPacePoint(to date: Date) -> PaceChartPoint? {
        Self.nearest(in: paceSelectionPoints, to: date, date: \.timestamp)
    }

    func nearestElevationPoint(to date: Date) -> RoutePoint? {
        Self.nearest(in: elevationPoints, to: date, date: \.timestamp)
    }

    private static func downsample<Element>(
        _ values: [Element],
        limit: Int
    ) -> [Element] {
        guard values.count > limit, limit > 1 else { return values }
        let interval = Double(values.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            values[
                min(
                    values.count - 1,
                    Int((Double(index) * interval).rounded())
                )
            ]
        }
    }

    private static func downsampleChart<Element>(
        _ values: [Element],
        limit: Int,
        value: (Element) -> Double
    ) -> [Element] {
        guard values.count > limit, limit >= 4 else { return values }
        let bucketCount = (limit - 2) / 2
        let interiorCount = values.count - 2
        var result = [values[0]]
        result.reserveCapacity(limit)

        for bucket in 0..<bucketCount {
            let start = 1 + interiorCount * bucket / bucketCount
            let end = min(
                values.count - 1,
                1 + interiorCount * (bucket + 1) / bucketCount
            )
            guard start < end else { continue }

            var minimumIndex = start
            var maximumIndex = start
            for index in (start + 1)..<end {
                if value(values[index]) < value(values[minimumIndex]) {
                    minimumIndex = index
                }
                if value(values[index]) > value(values[maximumIndex]) {
                    maximumIndex = index
                }
            }

            if minimumIndex == maximumIndex {
                result.append(values[minimumIndex])
            } else if minimumIndex < maximumIndex {
                result.append(values[minimumIndex])
                result.append(values[maximumIndex])
            } else {
                result.append(values[maximumIndex])
                result.append(values[minimumIndex])
            }
        }

        result.append(values[values.count - 1])
        return result
    }

    private static func paceChartPoints(
        metrics: [RouteMetricPoint],
        settings: MetricCalculationSettings
    ) -> [PaceChartPoint] {
        guard let firstDate = metrics.first?.timestamp,
              let lastDate = metrics.last?.timestamp else {
            return []
        }
        let workoutDuration = lastDate.timeIntervalSince(firstDate)
        guard workoutDuration.isFinite, workoutDuration >= 0 else {
            return []
        }
        let windowDuration = max(
            minimumPaceWindowDuration,
            ceil(workoutDuration / Double(chartPointLimit))
        )
        var windows: [PaceWindowKey: PaceWindowAccumulator] = [:]

        for routeMetrics in Dictionary(grouping: metrics, by: \.routeID).values {
            let ordered = routeMetrics.sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.sequence < $1.sequence
                }
                return $0.timestamp < $1.timestamp
            }
            for (previous, metric) in zip(ordered, ordered.dropFirst()) {
                let duration = metric.timestamp.timeIntervalSince(previous.timestamp)
                guard metric.sequence == previous.sequence + 1,
                      duration.isFinite,
                      duration > 0,
                      duration <= settings.maximumRouteGap,
                      metric.segmentDistanceMeters.isFinite,
                      metric.segmentDistanceMeters >= 0 else {
                    continue
                }
                let speed =
                    metric.derivedSpeedMetersPerSecond
                    ?? (metric.segmentDistanceMeters / duration)
                guard speed.isFinite,
                      speed >= settings.movingSpeedThresholdMetersPerSecond,
                      speed <= settings.maximumPlausibleSpeedMetersPerSecond else {
                    continue
                }
                let elapsed = metric.timestamp.timeIntervalSince(firstDate)
                guard elapsed.isFinite, elapsed >= 0 else { continue }
                let windowIndex = Int(floor(elapsed / windowDuration))
                let key = PaceWindowKey(
                    routeID: metric.routeID,
                    index: windowIndex
                )
                var accumulator =
                    windows[key]
                    ?? PaceWindowAccumulator(representativeMetric: metric)
                accumulator.distanceMeters += metric.segmentDistanceMeters
                accumulator.movingDuration += duration
                accumulator.representativeMetric = metric
                windows[key] = accumulator
            }
        }

        let groupedWindows = Dictionary(
            grouping: windows,
            by: \.key.routeID
        )
        var output: [PaceChartPoint] = []
        var seriesID = 0

        for routeWindows in groupedWindows.values {
            let ordered = routeWindows.sorted { $0.key.index < $1.key.index }
            var previousWindowIndex: Int?
            for (key, accumulator) in ordered {
                guard accumulator.movingDuration > 0 else { continue }
                let speed =
                    accumulator.distanceMeters
                    / accumulator.movingDuration
                let pace = speed > 0 ? 1_000 / speed : .infinity
                guard speed.isFinite,
                      speed >= settings.movingSpeedThresholdMetersPerSecond,
                      speed <= settings.maximumPlausibleSpeedMetersPerSecond,
                      pace.isFinite else {
                    continue
                }
                if previousWindowIndex.map({ key.index > $0 + 1 }) ?? true {
                    seriesID += 1
                }
                output.append(
                    PaceChartPoint(
                        metric: accumulator.representativeMetric,
                        speedMetersPerSecond: speed,
                        paceSecondsPerKilometer: pace,
                        seriesID: seriesID
                    )
                )
                previousWindowIndex = key.index
            }
        }
        return output.sorted { $0.timestamp < $1.timestamp }
    }

    private static func isValidMapPoint(_ point: RoutePoint) -> Bool {
        point.timestamp.timeIntervalSinceReferenceDate.isFinite
            && point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }

    private static func nearest<Element>(
        in values: [Element],
        to target: Date,
        date: KeyPath<Element, Date>
    ) -> Element? {
        guard !values.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = values.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if values[middle][keyPath: date] < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 { return values[0] }
        if lowerBound == values.count { return values[values.count - 1] }

        let before = values[lowerBound - 1]
        let after = values[lowerBound]
        return target.timeIntervalSince(before[keyPath: date])
            <= after[keyPath: date].timeIntervalSince(target)
            ? before
            : after
    }
}

struct WorkoutChartDomain: Equatable, Sendable {
    let date: ClosedRange<Date>
    let value: ClosedRange<Double>

    init?<Element>(
        points: [Element],
        date: KeyPath<Element, Date>,
        value: (Element) -> Double,
        minimumValuePadding: Double
    ) {
        let validPoints = points.filter {
            $0[keyPath: date].timeIntervalSinceReferenceDate.isFinite
                && value($0).isFinite
        }
        guard let first = validPoints.first, let last = validPoints.last else {
            return nil
        }

        let firstDate = first[keyPath: date]
        let lastDate = last[keyPath: date]
        if firstDate == lastDate {
            self.date = (
                firstDate.addingTimeInterval(-0.5)
            )...(
                lastDate.addingTimeInterval(0.5)
            )
        } else {
            self.date = firstDate...lastDate
        }

        let values = validPoints.map(value)
        guard let minimum = values.min(), let maximum = values.max() else {
            return nil
        }
        let padding = max(
            (maximum - minimum) * 0.08,
            minimumValuePadding
        )
        self.value = (minimum - padding)...(maximum + padding)
    }
}

struct PaceChartPoint: Identifiable, Sendable {
    var id: UUID { metric.id }
    let metric: RouteMetricPoint
    let speedMetersPerSecond: Double
    let paceSecondsPerKilometer: Double
    let seriesID: Int

    var routePointID: UUID { metric.routePointID }
    var timestamp: Date { metric.timestamp }
}

private struct PaceWindowKey: Hashable {
    let routeID: UUID
    let index: Int
}

private struct PaceWindowAccumulator {
    var representativeMetric: RouteMetricPoint
    var distanceMeters = 0.0
    var movingDuration: TimeInterval = 0
}

struct MapRoutePresentation: Identifiable, Sendable {
    let id: UUID
    let points: [RoutePoint]
}

struct RouteBounds: Sendable {
    let minimumLatitude: Double
    let maximumLatitude: Double
    let minimumLongitude: Double
    let maximumLongitude: Double

    init?(points: [RoutePoint]) {
        guard let first = points.first else { return nil }
        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude

        for point in points.dropFirst() {
            minimumLatitude = min(minimumLatitude, point.latitude)
            maximumLatitude = max(maximumLatitude, point.latitude)
            minimumLongitude = min(minimumLongitude, point.longitude)
            maximumLongitude = max(maximumLongitude, point.longitude)
        }

        self.minimumLatitude = minimumLatitude
        self.maximumLatitude = maximumLatitude
        self.minimumLongitude = minimumLongitude
        self.maximumLongitude = maximumLongitude
    }
}
