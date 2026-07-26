import Foundation
import HealthKit
import XCTest

@testable import WorkoutExporter

final class HeartRateZoneTests: XCTestCase {
    func testAgeEstimateUsesAgeOnWorkoutDateAndTanakaFormula() throws {
        let calendar = utcGregorianCalendar
        let dateOfBirth = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 1980,
            month: 7,
            day: 27
        )
        let dayBeforeBirthday = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 26
                )))
        let birthday = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 27
                )))

        let before = try XCTUnwrap(
            AgeBasedMaximumHeartRateEstimate(
                dateOfBirthComponents: dateOfBirth,
                asOf: dayBeforeBirthday
            ))
        let after = try XCTUnwrap(
            AgeBasedMaximumHeartRateEstimate(
                dateOfBirthComponents: dateOfBirth,
                asOf: birthday
            ))

        XCTAssertEqual(before.ageYears, 45)
        XCTAssertEqual(before.maximumHeartRateBPM, 176.5, accuracy: 0.001)
        XCTAssertEqual(after.ageYears, 46)
        XCTAssertEqual(after.maximumHeartRateBPM, 175.8, accuracy: 0.001)
    }

    func testAgeEstimateRejectsFutureAndImplausibleBirthDates() throws {
        let calendar = utcGregorianCalendar
        let referenceDate = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 26
                )))

        XCTAssertNil(
            AgeBasedMaximumHeartRateEstimate(
                dateOfBirthComponents: DateComponents(
                    calendar: calendar,
                    year: 2027,
                    month: 1,
                    day: 1
                ),
                asOf: referenceDate
            ))
        XCTAssertNil(
            AgeBasedMaximumHeartRateEstimate(
                dateOfBirthComponents: DateComponents(
                    calendar: calendar,
                    year: 1800,
                    month: 1,
                    day: 1
                ),
                asOf: referenceDate
            ))
    }

    func testOlderZoneSettingsEnableAutomaticEstimationByDefault() throws {
        let data = Data(
            #"{"method":"percentMaximum","maximumHeartRateBPM":185}"#.utf8
        )

        let settings = try JSONDecoder().decode(
            HeartRateZoneSettings.self,
            from: data
        )

        XCTAssertTrue(settings.automaticallyEstimateMaximumHeartRate)
        XCTAssertEqual(settings.maximumHeartRateBPM, 185)
        XCTAssertEqual(settings.restingHeartRateBPM, 60)
    }

    func testHealthKitAuthorizationIncludesDateOfBirth() throws {
        let dateOfBirthType = try XCTUnwrap(
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)
        )

        XCTAssertTrue(HealthKitMappings.readTypes.contains(dateOfBirthType))
    }

    func testZoneRangeDescriptionsMatchCalculationBoundaries() {
        let zones = [
            HeartRateZoneResult(
                zone: 1,
                lowerBoundBPM: 0,
                upperBoundBPM: 114,
                duration: 1
            ),
            HeartRateZoneResult(
                zone: 2,
                lowerBoundBPM: 114,
                upperBoundBPM: 133,
                duration: 1
            ),
            HeartRateZoneResult(
                zone: 5,
                lowerBoundBPM: 171.5,
                upperBoundBPM: nil,
                duration: 1
            ),
        ]

        XCTAssertEqual(
            zones.map(\.rangeDescription),
            [
                "< 114 bpm",
                "114–132 bpm",
                "172+ bpm",
            ])
    }

    func testZoneDurationDescriptionsMatchAppleStyle() {
        XCTAssertEqual(
            HeartRateZoneResult(
                zone: 1,
                lowerBoundBPM: 0,
                upperBoundBPM: 100,
                duration: 22_409
            ).durationDescription,
            "6:13:29"
        )
        XCTAssertEqual(
            HeartRateZoneResult(
                zone: 2,
                lowerBoundBPM: 100,
                upperBoundBPM: 120,
                duration: 689
            ).durationDescription,
            "11:29"
        )
        XCTAssertEqual(
            HeartRateZoneResult(
                zone: 3,
                lowerBoundBPM: 120,
                upperBoundBPM: 140,
                duration: 0
            ).durationDescription,
            "00:00"
        )
    }

    func testCalculatedZoneBoundariesAreRoundedBeforeSamplesAreAssigned() async throws {
        var detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        detail.metricSettings.heartRateZones.automaticallyEstimateMaximumHeartRate = false
        detail.metricSettings.heartRateZones.maximumHeartRateBPM = 187

        let metrics = try await WorkoutMetricCalculator().calculate(detail: detail)
        let zones = try XCTUnwrap(metrics.heartRateZones)

        XCTAssertEqual(zones.compactMap(\.upperBoundBPM), [112, 131, 150, 168])
        XCTAssertTrue(zones.allSatisfy {
            $0.lowerBoundBPM.rounded() == $0.lowerBoundBPM
                && ($0.upperBoundBPM?.rounded() == $0.upperBoundBPM)
        })
    }

    @MainActor
    func testDetailModelAppliesHealthAgeEstimateBeforeZoneCalculation() async throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let client = BirthDateClient(detail: detail)
        let model = WorkoutDetailViewModel()
        var settings = MetricCalculationSettings()
        settings.heartRateZones.maximumHeartRateBPM = 190

        await model.load(
            id: detail.id,
            referenceDate: detail.summary.startDate,
            client: client,
            settings: settings
        )

        let loaded = try XCTUnwrap(model.loadedDetail)
        XCTAssertEqual(
            loaded.metricSettings.heartRateZones.maximumHeartRateBPM,
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(loaded.derived.heartRateZones?.count, 5)
    }

    @MainActor
    func testDetailModelUsesFallbackWhenDateOfBirthIsUnavailable() async throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let client = BirthDateClient(detail: detail, dateOfBirth: nil)
        let model = WorkoutDetailViewModel()
        var settings = MetricCalculationSettings()
        settings.heartRateZones.maximumHeartRateBPM = 187

        await model.load(
            id: detail.id,
            referenceDate: detail.summary.startDate,
            client: client,
            settings: settings
        )

        let loaded = try XCTUnwrap(model.loadedDetail)
        XCTAssertEqual(
            loaded.metricSettings.heartRateZones.maximumHeartRateBPM,
            187
        )
    }

    @MainActor
    func testDetailModelPreservesConfiguredMaximumWhenAutomaticEstimationIsOff() async throws {
        let detail = SyntheticWorkoutFactory.make(.cleanOutdoorRun)
        let client = BirthDateClient(detail: detail)
        let model = WorkoutDetailViewModel()
        var settings = MetricCalculationSettings()
        settings.heartRateZones.automaticallyEstimateMaximumHeartRate = false
        settings.heartRateZones.maximumHeartRateBPM = 187

        await model.load(
            id: detail.id,
            referenceDate: detail.summary.startDate,
            client: client,
            settings: settings
        )

        let loaded = try XCTUnwrap(model.loadedDetail)
        XCTAssertEqual(
            loaded.metricSettings.heartRateZones.maximumHeartRateBPM,
            187
        )
    }

    private var utcGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

@MainActor
extension WorkoutDetailViewModel {
    fileprivate var loadedDetail: WorkoutDetail? {
        guard case .loaded(let detail) = state else { return nil }
        return detail
    }
}

private actor BirthDateClient: HealthKitClient {
    nonisolated let isHealthDataAvailable = true
    private let detail: WorkoutDetail
    private let dateOfBirth: DateComponents?

    init(
        detail: WorkoutDetail,
        dateOfBirth: DateComponents? = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 1986,
            month: 1,
            day: 1
        )
    ) {
        self.detail = detail
        self.dateOfBirth = dateOfBirth
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        [detail.summary]
    }

    func fetchDateOfBirthComponents() async throws -> DateComponents? {
        dateOfBirth
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        guard id == detail.id else {
            throw WorkoutExporterError.noAccessibleData
        }
        var result = detail
        result.metricSettings = settings
        result.derived = try await WorkoutMetricCalculator().calculate(
            detail: result
        )
        return result
    }
}
