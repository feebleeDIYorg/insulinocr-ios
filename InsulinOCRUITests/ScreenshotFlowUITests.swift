import XCTest

@MainActor
final class ScreenshotFlowUITests: XCTestCase {
    func testShareImportCorrectionSimulationAndExport() {
        continueAfterFailure = false
        let scenarioName = "Synthetic QA \(UUID().uuidString.prefix(8))"
        let localizationArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_CH"]
        let app = XCUIApplication()
        app.launchArguments = localizationArguments + ["-ui-testing-reset"]
        app.launch()
        let finish = app.buttons["Einrichtung abschließen"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        app.buttons["onboarding.dia"].tap()
        app.buttons["6 h"].tap()
        app.buttons["onboarding.insulin"].tap()
        app.buttons["Fiasp, Peak 55 min"].tap()
        finish.tap()
        XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 5))
        app.launchArguments = localizationArguments

        let host = XCUIApplication(bundleIdentifier: "org.example.insulinocr.test-share-host")
        host.launchArguments = localizationArguments
        host.launch()
        let share = host.buttons["fixture.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        let destination = host.cells["InsulinOCR"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8), host.debugDescription)
        // The system share cell changes its padding between iOS versions.
        // Select its actual image instead of estimating a point in that cell.
        let namedActivityImage = destination.images.matching(identifier: "activityImageView").firstMatch
        let activityImage = namedActivityImage.exists ? namedActivityImage : destination.images.firstMatch
        XCTAssertTrue(activityImage.waitForExistence(timeout: 5), host.debugDescription)
        activityImage.tap()
        let returned = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Completed:"),
            evaluatedWith: host.staticTexts["fixture.result"])
        let completion = XCTWaiter.wait(for: [returned], timeout: 20)
        if completion != .completed {
            let failure = XCTAttachment(screenshot: host.screenshot())
            failure.name = "System share did not complete"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertEqual(completion, .completed, host.debugDescription)
        app.activate()
        if app.alerts["Hinweis"].waitForExistence(timeout: 8) {
            app.alerts["Hinweis"].buttons["OK"].tap()
        }
        XCTAssertTrue(caseRow(in: app).waitForExistence(timeout: 30), app.debugDescription)
        caseRow(in: app).tap()
        let correctAction = app.buttons["Korrigieren"]
        XCTAssertTrue(correctAction.waitForExistence(timeout: 5), app.debugDescription)
        // UIKit menus capture enabled states when presented. Wait on the live
        // SwiftUI control before opening a menu during a newly imported analysis.
        let importedAnalysisReady = expectation(
            for: NSPredicate(format: "enabled == true"), evaluatedWith: correctAction)
        XCTAssertEqual(XCTWaiter.wait(for: [importedAnalysisReady], timeout: 30), .completed,
                       app.debugDescription)
        // Re-imports deduplicate. Exercise the current extractor and retain the
        // prior immutable analysis/corrections when repeating this test.
        toolbarAction("case.actions", in: app).tap()
        let reanalyze = app.buttons["Screenshot erneut analysieren"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: reanalyze)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        reanalyze.tap()
        XCTAssertTrue(app.staticTexts["Vollständig"].waitForExistence(timeout: 30), app.debugDescription)
        let baseline = metric("Basal IOB", in: app).label
        app.buttons["Korrigieren"].tap()
        let amount = app.textFields.matching(identifier: "Menge").firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5), app.debugDescription)
        // The importer deliberately deduplicates identical images. A repeat run must
        // create a real new correction even when the prior synthetic case persists.
        let currentAmount = Double((amount.value as? String ?? "").replacingOccurrences(of: ",", with: "."))
        let correctedAmount = currentAmount == 0.9 ? "0.8" : "0.9"
        replace(amount, with: correctedAmount)
        app.buttons["Revision speichern"].tap()
        let savedCorrection = expectation(for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["Revision speichern"])
        XCTAssertEqual(XCTWaiter.wait(for: [savedCorrection], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["Korrigieren"].waitForExistence(timeout: 10), app.debugDescription)
        let corrected = app.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@ AND label != %@", "Basal IOB, [0-9]+[.,][0-9]{2}, IE", baseline
        )).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 10), app.debugDescription)
        let correctedLabel = corrected.label
        toolbarAction("Simulation", in: app).tap()
        XCTAssertTrue(app.textFields["simulation.name"].waitForExistence(timeout: 5), app.debugDescription)
        replace(app.textFields["simulation.name"], with: scenarioName)
        replace(app.textFields["simulation.bolus"], with: "1")
        replace(app.textFields["simulation.carbs"], with: "15")
        XCTAssertTrue(app.staticTexts["Bolus IOB, Basis, Szenario, Delta, 0.00 IE, 1.00 IE, +1.00 IE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Aktive KH, Basis, Szenario, Delta, 0.00 g, 15.00 g, +15.00 g"].exists)
        app.buttons["Szenario speichern"].tap()
        XCTAssertTrue(app.staticTexts[scenarioName].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Schließen"].tap()
        XCTAssertEqual(metric("Basal IOB", in: app).label, correctedLabel)
        XCTAssertEqual(metric("Bolus IOB", in: app).label, "Bolus IOB, 0.00, IE")
        XCTAssertEqual(metric("Aktive KH", in: app).label, "Aktive KH, 0.00, g")

        // Removing a critical amount must hide every activity result, including
        // saved simulations, until a further immutable revision restores it.
        app.buttons["Korrigieren"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5), app.debugDescription)
        replace(amount, with: "")
        app.buttons["Revision speichern"].tap()
        let unavailable = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Basal IOB, Nicht verfügbar"
        )).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10), app.debugDescription)
        for title in ["Basal IOB", "Bolus IOB", "Gesamt IOB", "Aktive KH"] {
            XCTAssertTrue(metric(title, in: app).label.contains("Nicht verfügbar"))
        }
        let simulationNeedsOverflow = !app.buttons["Simulation"].exists
        XCTAssertFalse(toolbarAction("Simulation", in: app).isEnabled)
        if simulationNeedsOverflow {
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertFalse(app.staticTexts["Aktives Insulin – Zukunftsabbau"].exists)
        XCTAssertFalse(app.staticTexts["Aktive Kohlenhydrate – Zukunftsabbau"].exists)
        app.buttons["Korrigieren"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5), app.debugDescription)
        replace(amount, with: correctedAmount)
        app.buttons["Revision speichern"].tap()
        XCTAssertTrue(app.staticTexts[correctedLabel].waitForExistence(timeout: 10))

        toolbarAction("case.actions", in: app).tap()
        app.buttons["QA-Archiv exportieren"].tap()
        let exportClose = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label == %@",
            "header.closeButton", "Schließen", "Close"
        )).firstMatch
        XCTAssertTrue(exportClose.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@", "In Dateien sichern", "Save to Files"
        )).firstMatch.exists)
        exportClose.tap()

        for reopen in 1...3 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 5))
            caseRow(in: app).tap()
            XCTAssertTrue(app.staticTexts[correctedLabel].waitForExistence(timeout: 5),
                "Persisted case failed to reopen \(reopen): \(app.debugDescription)")
            XCTAssertTrue(app.staticTexts["2. Jan. 2026, 12:00"].exists)
            for _ in 0..<3 { app.swipeUp() }
            XCTAssertTrue(app.staticTexts["Aktive Kohlenhydrate – Zukunftsabbau"].exists)
            for _ in 0..<3 { app.swipeDown() }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Synthetic screenshot share flow"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toolbarAction("Simulation", in: app).tap()
        for _ in 0..<6 where !app.staticTexts[scenarioName].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts[scenarioName].exists, app.debugDescription)
        app.buttons["Schließen"].tap()
    }

    private func toolbarAction(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // UIKit recreates overflow menu entries without SwiftUI identifiers on iOS 18.
        let title = identifier == "case.actions" ? "Weitere Aktionen" : identifier
        let action = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", identifier, title
        )).firstMatch
        if !action.exists {
            // Narrow navigation bars expose trailing actions through native overflow.
            let overflow = app.navigationBars.buttons.matching(NSPredicate(
                format: "label IN %@", ["Weitere", "More"]
            )).firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 5), app.debugDescription)
            overflow.tap()
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        return action
    }

    private func caseRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "case.row."
        )).firstMatch
    }

    private func metric(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let metric = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
        XCTAssertTrue(metric.waitForExistence(timeout: 5))
        return metric
    }

    private func replace(_ field: XCUIElement, with value: String) {
        if field.identifier == "simulation.name" {
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        }
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + value)
    }
}
