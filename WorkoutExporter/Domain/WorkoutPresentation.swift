import Foundation

struct WorkoutRouteCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
}

struct WorkoutRoutePreview: Hashable, Sendable {
    var workoutID: UUID
    var segments: [[WorkoutRouteCoordinate]]

    var coordinates: [WorkoutRouteCoordinate] {
        segments.flatMap { $0 }
    }
}

enum WorkoutPlaceKind: String, Sendable {
    case hike
    case neighborhood
}

struct WorkoutPlaceLabel: Equatable, Sendable {
    var name: String
    var kind: WorkoutPlaceKind
    var source: String
}

enum WorkoutActivityPresentation {
    static func symbolName(for activityName: String) -> String {
        let name = activityName.lowercased()
        if name.contains("hiking") || name.contains("hike") { return "figure.hiking" }
        if name.contains("walking") || name.contains("walk") { return "figure.walk" }
        if name.contains("running") || name.contains("run") { return "figure.run" }
        if name.contains("cycling") || name.contains("cycle") || name.contains("bike") { return "bicycle" }
        if name.contains("swimming") || name.contains("swim") { return "figure.pool.swim" }
        if name.contains("rowing") || name.contains("row") { return "figure.rower" }
        if name.contains("elliptical") { return "figure.elliptical" }
        if name.contains("stair") { return "figure.stair.stepper" }
        if name.contains("strength") { return "dumbbell.fill" }
        if name.contains("interval") || name == "hiit" { return "figure.highintensity.intervaltraining" }
        if name.contains("snow") || name.contains("ski") { return "figure.skiing.downhill" }
        if name.contains("climbing") || name.contains("climb") { return "figure.climbing" }
        return "figure.mixed.cardio"
    }

    static func placeKind(for activityName: String) -> WorkoutPlaceKind? {
        let name = activityName.lowercased()
        if name.contains("hiking") || name.contains("hike") { return .hike }
        if name.contains("running") || name.contains("run")
            || name.contains("walking") || name.contains("walk") {
            return .neighborhood
        }
        return nil
    }
}

struct WorkoutPlaceCandidate: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

enum WorkoutPlaceNameSelector {
    static func select(
        kind: WorkoutPlaceKind,
        candidates: [WorkoutPlaceCandidate],
        route: [WorkoutRouteCoordinate]
    ) -> WorkoutPlaceLabel? {
        guard !route.isEmpty else { return nil }
        let valid = candidates.compactMap { candidate -> (WorkoutPlaceCandidate, Double)? in
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCredible(name: name, kind: kind) else { return nil }
            let distance = representativeRoute(route).map {
                distanceMeters(
                    fromLatitude: candidate.latitude,
                    longitude: candidate.longitude,
                    toLatitude: $0.latitude,
                    longitude: $0.longitude
                )
            }.min() ?? .infinity
            guard distance <= maximumDistance(for: kind) else { return nil }
            var normalized = candidate
            normalized.name = name
            return (normalized, distance)
        }
        guard let best = valid.min(by: {
            if $0.1 == $1.1 { return $0.0.name < $1.0.name }
            return $0.1 < $1.1
        })?.0 else {
            return nil
        }
        return WorkoutPlaceLabel(name: best.name, kind: kind, source: "Apple Maps")
    }

    private static func representativeRoute(
        _ route: [WorkoutRouteCoordinate],
        limit: Int = 64
    ) -> [WorkoutRouteCoordinate] {
        guard route.count > limit, limit > 1 else { return route }
        let step = Double(route.count - 1) / Double(limit - 1)
        return (0..<limit).map {
            route[min(route.count - 1, Int((Double($0) * step).rounded()))]
        }
    }

    private static func isCredible(name: String, kind: WorkoutPlaceKind) -> Bool {
        guard name.count >= 3, name.count <= 100 else { return false }
        let normalized = name.lowercased()
        let rejected = [
            "hiking", "hiking trail", "trail", "neighborhood", "current location",
            "unknown", "unnamed road"
        ]
        guard !rejected.contains(normalized) else { return false }
        switch kind {
        case .hike:
            return !normalized.hasPrefix("route ")
        case .neighborhood:
            let streetOnlySuffixes = [
                " street", " st", " avenue", " ave", " road", " rd", " boulevard",
                " blvd", " drive", " dr", " lane", " ln", " way"
            ]
            return !streetOnlySuffixes.contains(where: normalized.hasSuffix)
        }
    }

    private static func maximumDistance(for kind: WorkoutPlaceKind) -> Double {
        switch kind {
        case .hike: 1_500
        case .neighborhood: 3_000
        }
    }

    private static func distanceMeters(
        fromLatitude: Double,
        longitude: Double,
        toLatitude: Double,
        longitude otherLongitude: Double
    ) -> Double {
        let earthRadius = 6_371_000.0
        let firstLatitude = fromLatitude * .pi / 180
        let secondLatitude = toLatitude * .pi / 180
        let latitudeDelta = (toLatitude - fromLatitude) * .pi / 180
        let longitudeDelta = (otherLongitude - longitude) * .pi / 180
        let value = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(value), sqrt(1 - value))
    }
}
