import XCTest

final class ActivityArchiveMacUITests: XCTestCase {
  @MainActor
  func testFirstRunExplainsLocalStorageAndBackupBeforeSetup() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-onboarding"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Activity Archive"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Stored only in the folder you choose"].exists)
    XCTAssertTrue(app.staticTexts["Original imports remain unchanged"].exists)
    XCTAssertTrue(app.staticTexts["Protected by your Mac and volume security"].exists)
    XCTAssertTrue(app.staticTexts["vault-security-guidance"].exists)
    XCTAssertTrue(app.buttons["create-vault-button"].exists)
    XCTAssertTrue(app.buttons["open-vault-button"].exists)
  }

  @MainActor
  func testMissingBookmarkShowsRecoverableVaultSelection() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-recovery"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["vault-recovery-message"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["Vault access needs to be restored"].exists)
    XCTAssertTrue(app.buttons["open-vault-button"].exists)
  }

  @MainActor
  func testReadyVaultExposesOpenAndDropImportEntryPoints() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-ready"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Import Activities"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["open-import-files-button"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["file-import-drop-zone"].exists)
    XCTAssertTrue(
      app.staticTexts[
        "Original files are copied into immutable storage before they are inspected."
      ].exists
    )
  }
}

extension ActivityArchiveMacUITests {
  @MainActor
  func testCatalogSearchSelectionAndRouteAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-catalog"]
    app.launch()
    let activities = app.descendants(matching: .any)["navigation-activities"].firstMatch
    XCTAssertTrue(activities.waitForExistence(timeout: 10))
    activities.click()
    XCTAssertTrue(app.staticTexts["source-observation-notice"].waitForExistence(timeout: 5))
    let row = app.descendants(matching: .any)["source-row-1"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.click()
    XCTAssertTrue(app.buttons["load-source-overlay"].waitForExistence(timeout: 5))
    app.buttons["load-source-overlay"].click()
    XCTAssertTrue(app.staticTexts["route-derivative-notice"].waitForExistence(timeout: 10))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Source route display derivative"
    attachment.lifetime = .keepAlways
    add(attachment)
    let search = app.textFields["catalog-search"]
    search.click()
    search.typeText("does not match")
    XCTAssertTrue(app.staticTexts["catalog-page-status"].waitForExistence(timeout: 5))
    let predicate = NSPredicate(
      format: "value CONTAINS %@ OR label CONTAINS %@", "0 on this page", "0 on this page")
    expectation(for: predicate, evaluatedWith: app.staticTexts["catalog-page-status"])
    waitForExpectations(timeout: 5)
  }

  @MainActor
  func testImportHistoryAndIntegrityRecoveryControls() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing-catalog"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Import Activities"].waitForExistence(timeout: 10))
    app.descendants(matching: .any)["navigation-integrity"].firstMatch.click()
    let check = app.buttons["check-integrity-button"]
    XCTAssertTrue(check.waitForExistence(timeout: 5))
    check.click()
    let status = app.staticTexts["vault-integrity-status"]
    expectation(
      for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Healthy:", "Healthy:"),
      evaluatedWith: status)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(app.buttons["Close Vault"].exists)
    app.buttons["Close Vault"].click()
    XCTAssertTrue(app.buttons["open-vault-button"].waitForExistence(timeout: 5))
  }
}
