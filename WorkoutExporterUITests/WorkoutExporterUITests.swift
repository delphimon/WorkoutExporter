import XCTest

final class WorkoutExporterUITests: XCTestCase {
    @MainActor
    func testOnboardingExplainsPrivacyAndOpensSyntheticWorkouts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your workouts.\nYour files."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Processed on this iPhone"].exists)
        XCTAssertTrue(app.staticTexts["Read only"].exists)
        app.buttons["Explore with Sample Workouts"].tap()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["workout-list"].exists || app.collectionViews.firstMatch.exists)
    }

    @MainActor
    func testListFilterDetailAndExportFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))
        app.buttons["workout-filter-button"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Has GPS route"].exists)
        XCTAssertTrue(app.switches["Has heart-rate data"].exists)
        app.buttons["Done"].tap()

        let firstWorkout = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstWorkout.waitForExistence(timeout: 5))
        firstWorkout.tap()
        XCTAssertTrue(app.buttons["workout-export-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["detail-section-picker"].exists)

        app.buttons["workout-export-button"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Raw samples"].exists)
        XCTAssertTrue(app.switches["GPS route"].exists)
        XCTAssertTrue(app.buttons["create-export-button"].isEnabled)
        app.buttons["create-export-button"].tap()
        scrollExportFormToBottom(in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share'"))
                .firstMatch.waitForExistence(timeout: 30)
        )
    }

    @MainActor
    func testMissingRouteState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))

        let noRoute = app.descendants(matching: .any)[
            "workout-row-00000000-0000-0000-0000-000000000004"
        ]
        XCTAssertTrue(noRoute.waitForExistence(timeout: 5))
        noRoute.tap()
        XCTAssertTrue(app.buttons["detail-section-picker"].waitForExistence(timeout: 10))
        app.buttons["detail-section-picker"].tap()
        app.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["No GPS Route"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testMissingHeartRateState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))
        app.collectionViews.firstMatch.swipeUp()
        let noHeartRate = app.descendants(matching: .any)[
            "workout-row-00000000-0000-0000-0000-000000000005"
        ]
        XCTAssertTrue(noHeartRate.waitForExistence(timeout: 5))
        noHeartRate.tap()
        XCTAssertTrue(app.buttons["detail-section-picker"].waitForExistence(timeout: 10))
        app.buttons["detail-section-picker"].tap()
        app.buttons["Heart Rate"].tap()
        XCTAssertTrue(app.staticTexts["No Heart-Rate Data"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testExportErrorIsRecoverableAndVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-export-error"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))
        let firstWorkout = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstWorkout.waitForExistence(timeout: 5))
        firstWorkout.tap()
        XCTAssertTrue(app.buttons["workout-export-button"].waitForExistence(timeout: 10))
        app.buttons["workout-export-button"].tap()
        app.buttons["create-export-button"].tap()
        scrollExportFormToBottom(in: app)
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'UI test export failure'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["create-export-button"].isEnabled)
    }

    @MainActor
    private func scrollExportFormToBottom(in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<4 { form.swipeUp() }
    }
}
