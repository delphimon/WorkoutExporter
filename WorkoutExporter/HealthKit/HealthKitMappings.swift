import Foundation
import HealthKit

enum HealthKitMappings {
    static let quantityTypes: [(type: HKQuantityType, unit: HKUnit, reason: String)] = {
        var values: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
            (.heartRate, .count().unitDivided(by: .minute()), "Heart-rate charts, statistics, zones, and exports."),
            (.distanceWalkingRunning, .meter(), "Walking, running, and hiking distance samples."),
            (.distanceCycling, .meter(), "Cycling distance samples."),
            (.distanceSwimming, .meter(), "Swimming distance samples."),
            (.activeEnergyBurned, .kilocalorie(), "Active energy recorded during workouts."),
            (.basalEnergyBurned, .kilocalorie(), "Basal energy when associated with a workout."),
            (.runningSpeed, .meter().unitDivided(by: .second()), "Native running speed takes precedence over derived speed."),
            (.walkingSpeed, .meter().unitDivided(by: .second()), "Native walking speed takes precedence over derived speed."),
            (.cyclingSpeed, .meter().unitDivided(by: .second()), "Native cycling speed takes precedence over derived speed."),
            (.cyclingCadence, .count().unitDivided(by: .minute()), "Cycling cadence export."),
            (.runningPower, .watt(), "Running power export."),
            (.cyclingPower, .watt(), "Cycling power export."),
            (.stepCount, .count(), "Steps associated with a workout; the SDK exposes no separate running-cadence identifier."),
            (.swimmingStrokeCount, .count(), "Swimming stroke count associated with a workout."),
            (.flightsClimbed, .count(), "Flights climbed associated with a workout."),
            (.respiratoryRate, .count().unitDivided(by: .minute()), "Respiratory rate associated with a workout."),
            (.oxygenSaturation, .percent(), "Blood oxygen when the platform and local law make it accessible.")
        ]
        if #available(iOS 18.0, *) {
            values.append((.distanceRowing, .meter(), "Rowing distance samples."))
        }
        return values.compactMap { identifier, unit, reason in
            HKObjectType.quantityType(forIdentifier: identifier).map { ($0, unit, reason) }
        }
    }()

    static let categoryTypes: [HKCategoryType] = []

    static var readTypes: Set<HKObjectType> {
        var types = Set(quantityTypes.map(\.type) as [HKObjectType])
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        categoryTypes.forEach { types.insert($0) }
        return types
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .hiking: "Hiking"
        case .walking: "Walking"
        case .running: "Running"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair Climbing"
        case .crossTraining: "Cross Training"
        case .traditionalStrengthTraining: "Strength Training"
        case .functionalStrengthTraining: "Functional Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .snowSports: "Snow Sports"
        case .climbing: "Climbing"
        case .swimBikeRun: "Multisport"
        case .other: "Other"
        default: type.name.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        }
    }

    static func eventKind(_ type: HKWorkoutEventType) -> WorkoutEventKind {
        switch type {
        case .pause, .motionPaused: .pause
        case .resume, .motionResumed: .resume
        case .lap: .lap
        case .segment: .segment
        case .marker: .marker
        default: .unknown
        }
    }

    static func source(_ revision: HKSourceRevision) -> SourceInfo {
        let os = revision.operatingSystemVersion
        return SourceInfo(
            name: revision.source.name,
            bundleIdentifier: revision.source.bundleIdentifier,
            version: revision.version,
            operatingSystemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }

    static func device(_ device: HKDevice?) -> DeviceInfo? {
        guard let device else { return nil }
        return DeviceInfo(
            name: device.name,
            manufacturer: device.manufacturer,
            model: device.model,
            hardwareVersion: device.hardwareVersion,
            softwareVersion: device.softwareVersion,
            localIdentifier: device.localIdentifier,
            firmwareVersion: device.firmwareVersion
        )
    }

    static func safeMetadata(_ metadata: [String: Any]?) -> [String: String] {
        guard let metadata else { return [:] }
        return metadata.reduce(into: [:]) { result, pair in
            switch pair.value {
            case let value as String: result[pair.key] = value
            case let value as NSNumber: result[pair.key] = value.stringValue
            case let value as Date: result[pair.key] = value.formatted(.iso8601)
            case let value as HKQuantity: result[pair.key] = value.description
            default: result[pair.key] = String(describing: pair.value)
            }
        }
    }

    static func unit(for type: HKQuantityType) -> HKUnit {
        quantityTypes.first(where: { $0.type == type })?.unit ?? .count()
    }
}

private extension HKWorkoutActivityType {
    var name: String {
        String(describing: self)
    }
}
