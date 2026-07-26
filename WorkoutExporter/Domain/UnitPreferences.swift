import Foundation

enum DistanceUnitPreference: String, CaseIterable, Codable, Sendable {
    case metric
    case usCustomary

    var label: String { self == .metric ? "Metric" : "US customary" }
    var distanceUnit: UnitLength { self == .metric ? .kilometers : .miles }
    var elevationUnit: UnitLength { self == .metric ? .meters : .feet }
    var speedUnit: UnitSpeed { self == .metric ? .kilometersPerHour : .milesPerHour }
    var paceUnitLabel: String { self == .metric ? "km" : "mi" }

    func distanceValue(fromMeters meters: Double) -> Double {
        Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: distanceUnit)
            .value
    }

    func meters(fromDistanceValue value: Double) -> Double {
        Measurement(value: value, unit: distanceUnit)
            .converted(to: .meters)
            .value
    }

    var distanceSliderStep: Double { 0.1 }
}

enum ExportFilenameFormat: String, CaseIterable, Codable, Sendable {
    case dateActivityIdentifier
    case activityDateIdentifier

    var label: String {
        switch self {
        case .dateActivityIdentifier: "Date · Activity · ID"
        case .activityDateIdentifier: "Activity · Date · ID"
        }
    }
}

struct MeasurementFormatterFactory {
    static func distanceSliderValue(
        _ meters: Double,
        preference: DistanceUnitPreference
    ) -> String {
        let value = preference.distanceValue(fromMeters: meters)
        return value.formatted(.number.precision(.fractionLength(1)))
            + " "
            + (preference == .metric ? "km" : "mi")
    }

    static func distance(_ meters: Double?, preference: DistanceUnitPreference) -> String {
        guard let meters else { return "—" }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: preference.distanceUnit)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...2)))
        )
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: seconds >= 3_600 ? 2 : 0)))
    }

    static func pace(secondsPerKilometer: Double?, preference: DistanceUnitPreference) -> String {
        guard let secondsPerKilometer, secondsPerKilometer.isFinite else { return "—" }
        let seconds = preference == .metric ? secondsPerKilometer : secondsPerKilometer * 1.609_344
        return "\(duration(seconds))/\(preference.paceUnitLabel)"
    }

    static func elevation(_ meters: Double?, preference: DistanceUnitPreference) -> String {
        guard let meters else { return "—" }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: preference.elevationUnit)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
        )
    }

    static func speed(_ metersPerSecond: Double?, preference: DistanceUnitPreference) -> String {
        guard let metersPerSecond else { return "—" }
        let measurement = Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
            .converted(to: preference.speedUnit)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))
        )
    }
}
