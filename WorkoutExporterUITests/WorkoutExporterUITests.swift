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
        let mappedWorkout = app.descendants(matching: .any)[
            "workout-row-00000000-0000-0000-0000-000000000001"
        ]
        XCTAssertTrue(mappedWorkout.waitForExistence(timeout: 5))
        XCTAssertTrue(mappedWorkout.label.contains("Running"))
        XCTAssertTrue(mappedWorkout.label.contains("Workout route map preview"))
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
        XCTAssertTrue(
            app.buttons["edit-detail-location-tag-button"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["detail-section-picker"].tap()
        app.buttons["Heart Rate"].tap()
        XCTAssertTrue(
            app.maps["synchronized-route-map"].waitForExistence(timeout: 5)
                || app.otherElements["synchronized-route-map"]
                    .waitForExistence(timeout: 5)
        )

        app.buttons["workout-export-button"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["Raw samples"].exists)
        XCTAssertTrue(app.switches["GPS route"].exists)
        XCTAssertTrue(app.buttons["create-export-button"].isEnabled)
        app.buttons["create-export-button"].tap()
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
        XCTAssertTrue(noRoute.label.contains("Workout route map preview"))
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
    func testBatchExportHistoryFilterClearAndCachedShare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))

        let firstID = "00000000-0000-0000-0000-000000000001"
        let secondID = "00000000-0000-0000-0000-000000000002"
        app.buttons["Select"].tap()
        let first = app.descendants(matching: .any)["workout-row-\(firstID)"]
        let second = app.descendants(matching: .any)["workout-row-\(secondID)"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        first.tap()
        second.tap()

        app.buttons["export-selected-workouts-button"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 5))
        app.buttons["create-export-button"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share'"))
                .firstMatch.waitForExistence(timeout: 30)
        )
        app.buttons["Close"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["workout-exported-\(firstID)"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workout-exported-\(secondID)"].exists)
        app.buttons["export-selected-workouts-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["share-existing-export-button"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["Close"].tap()

        app.buttons["workout-filter-button"].tap()
        let unexported = app.switches["unexported-only-filter"]
        XCTAssertTrue(unexported.waitForExistence(timeout: 5))
        unexported.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        XCTAssertEqual(unexported.value as? String, "1")
        app.navigationBars["Filters"].buttons["Done"].tap()

        app.buttons["selected-workout-actions-button"].tap()
        app.buttons["Mark Selected Not Exported"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
    }

    @MainActor
    func testManualLocationTagDoesNotRenameActivityType() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Sample Workouts"].waitForExistence(timeout: 5))

        let workoutID = "00000000-0000-0000-0000-000000000001"
        app.buttons["Select"].tap()
        let workout = app.descendants(matching: .any)["workout-row-\(workoutID)"]
        XCTAssertTrue(workout.waitForExistence(timeout: 5))
        workout.tap()
        app.buttons["selected-workout-actions-button"].tap()
        app.buttons["Edit Location Tag"].tap()
        let field = app.textFields["workout-location-tag-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Green Lake")
        app.buttons["save-workout-location-tag-button"].tap()
        app.buttons["Done"].tap()

        let activityType = app.staticTexts["workout-type-\(workoutID)"].firstMatch
        XCTAssertTrue(activityType.waitForExistence(timeout: 5))
        XCTAssertEqual(activityType.label, "Running")
        XCTAssertTrue(workout.label.contains("Green Lake"))
    }

    @MainActor
    private func scrollExportFormToBottom(in app: XCUIApplication) {
        let form = app.collectionViews["export-form"]
        for _ in 0..<4 { form.swipeUp() }
    }
}
