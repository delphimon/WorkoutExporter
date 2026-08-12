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

enum WorkoutPlaceKind: String, Codable, Sendable {
    case hike
    case neighborhood
}

struct WorkoutPlaceLabel: Codable, Equatable, Sendable {
    var name: String
    var kind: WorkoutPlaceKind
    var source: String
}

struct WorkoutActivityDescriptor: Equatable, Sendable {
    var identifier: UInt
    var name: String
    var symbolName: String
}

/// Stable user-facing metadata for every public HealthKit workout activity.
/// HealthKit's Objective-C enum otherwise describes unmapped cases as labels
/// such as `(rawValue: 48)`.
enum WorkoutActivityCatalog {
    private static let names: [UInt: String] = [
        1: "American Football", 2: "Archery", 3: "Australian Football",
        4: "Badminton", 5: "Baseball", 6: "Basketball", 7: "Bowling",
        8: "Boxing", 9: "Climbing", 10: "Cricket", 11: "Cross Training",
        12: "Curling", 13: "Cycling", 14: "Dance",
        15: "Dance Inspired Training", 16: "Elliptical",
        17: "Equestrian Sports", 18: "Fencing", 19: "Fishing",
        20: "Functional Strength Training", 21: "Golf", 22: "Gymnastics",
        23: "Handball", 24: "Hiking", 25: "Hockey", 26: "Hunting",
        27: "Lacrosse", 28: "Martial Arts", 29: "Mind and Body",
        30: "Mixed Metabolic Cardio Training", 31: "Paddle Sports",
        32: "Play", 33: "Preparation and Recovery", 34: "Racquetball",
        35: "Rowing", 36: "Rugby", 37: "Running", 38: "Sailing",
        39: "Skating Sports", 40: "Snow Sports", 41: "Soccer",
        42: "Softball", 43: "Squash", 44: "Stair Climbing",
        45: "Surfing Sports", 46: "Swimming", 47: "Table Tennis",
        48: "Tennis", 49: "Track and Field",
        50: "Traditional Strength Training", 51: "Volleyball", 52: "Walking",
        53: "Water Fitness", 54: "Water Polo", 55: "Water Sports",
        56: "Wrestling", 57: "Yoga", 58: "Barre", 59: "Core Training",
        60: "Cross-Country Skiing", 61: "Downhill Skiing", 62: "Flexibility",
        63: "High-Intensity Interval Training", 64: "Jump Rope",
        65: "Kickboxing", 66: "Pilates", 67: "Snowboarding", 68: "Stairs",
        69: "Step Training", 70: "Wheelchair Walk Pace",
        71: "Wheelchair Run Pace", 72: "Tai Chi", 73: "Mixed Cardio",
        74: "Hand Cycling", 75: "Disc Sports", 76: "Fitness Gaming",
        77: "Cardio Dance", 78: "Social Dance", 79: "Pickleball",
        80: "Cooldown", 82: "Swim Bike Run", 83: "Transition",
        84: "Underwater Diving", 2998: "Rest", 2999: "Group", 3000: "Other"
    ]

    static let all: [WorkoutActivityDescriptor] = names.map { identifier, name in
        WorkoutActivityDescriptor(
            identifier: identifier,
            name: name,
            symbolName: symbolName(for: identifier, fallbackName: name)
        )
    }.sorted { $0.identifier < $1.identifier }

    static func name(for identifier: UInt, fallbackName: String? = nil) -> String {
        if let name = names[identifier] { return name }
        if let fallbackName {
            let trimmed = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.localizedCaseInsensitiveContains("rawValue") {
                return trimmed
            }
        }
        return "Activity \(identifier)"
    }

    static func symbolName(for identifier: UInt, fallbackName: String? = nil) -> String {
        switch identifier {
        case 1, 3...8, 10, 12, 18, 21, 23, 25, 27, 34, 36, 41...43,
             47, 48, 51, 56, 75, 79: "sportscourt"
        case 13, 74: "bicycle"
        case 20, 50, 59: "dumbbell.fill"
        case 24: "figure.hiking"
        case 35: "figure.rower"
        case 37, 49, 71: "figure.run"
        case 44, 68, 69: "figure.stair.stepper"
        case 46: "figure.pool.swim"
        case 52, 70: "figure.walk"
        case 60, 61, 67: "figure.skiing.downhill"
        case 63: "figure.highintensity.intervaltraining"
        case 9: "figure.climbing"
        case 16: "figure.elliptical"
        case 45, 53...55, 84: "water.waves"
        case 29, 33, 57, 58, 62, 66, 72, 80: "figure.mind.and.body"
        case 14, 15, 77, 78: "figure.dance"
        case 82: "figure.mixed.cardio"
        default:
            WorkoutActivityPresentation.symbolName(
                for: fallbackName ?? names[identifier] ?? ""
            )
        }
    }
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
