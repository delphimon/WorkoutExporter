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
