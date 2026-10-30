import Foundation
import XCTest

final class OnboardingUITests: XCTestCase {
    func testExplicitSetupPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
        let finish = app.buttons["Einrichtung abschließen"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertFalse(finish.isEnabled)
        app.buttons["onboarding.dia"].tap()
        app.buttons["6 h"].tap()
        XCTAssertFalse(finish.isEnabled)
        app.buttons["onboarding.insulin"].tap()
        app.buttons["Fiasp, Peak 55 min"].tap()
        XCTAssertTrue(finish.isEnabled)
        finish.tap()
        XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Therapieverlauf aus einem Screenshot"].exists)
    }

    func testFirstLaunchRequiresExplicitTherapyParameters() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Therapieverlauf aus einem Screenshot"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Experimentelle Schätzung"].exists)
        XCTAssertFalse(app.buttons["Einrichtung abschließen"].isEnabled)
    }
}
