import XCTest

final class CaptureUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }
  func testCaptureAndRememberLibrary() throws {
    let app = XCUIApplication(bundleIdentifier: "org.researchlibrary.capture")
    app.launchEnvironment["RESEARCH_LIBRARY_UI_TEST"] = "1"
    app.launch()
    let input = app.descendants(matching: .any).matching(identifier: "captureInput").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("10.1000/ui-capture")
    let collection = app.textFields["captureCollection"]
    collection.tap()
    collection.typeText("UI Test Collection")
    let tags = app.textFields["captureTags"]
    tags.tap()
    tags.typeText("cortex, methods")
    app.buttons["captureSave"].tap()
    XCTAssertTrue(app.staticTexts["Saved to Inbox."].waitForExistence(timeout: 10))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Capture saved"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.terminate()
    app.launchEnvironment.removeValue(forKey: "RESEARCH_LIBRARY_UI_TEST")
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "captureInput").firstMatch
        .waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Capture File"].isEnabled)
  }
}
