import Foundation

enum DistanceUnitPreference: String, CaseIterable, Codable, Sendable {
    case metric
    case usCustomary

    var label: String { self == .metric ? "Metric" : "US customary" }
    var distanceUnit: UnitLength { self == .metric ? .kilometers : .miles }
}

struct MeasurementFormatterFactory {
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
        return "\(duration(seconds))/\(preference == .metric ? "km" : "mi")"
    }
}
