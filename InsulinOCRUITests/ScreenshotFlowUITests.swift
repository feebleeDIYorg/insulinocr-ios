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
        closeSimulationKeyboard(in: app)
        // Events are rows of a list; each starts at the capture time (offset 0).
        addSimulationEvent("Bolus", in: app)
        replace(app.textFields["simulation.amount.bolus"], with: "1")
        closeSimulationKeyboard(in: app)
        addSimulationEvent("Kohlenhydrate", in: app)
        replace(app.textFields["simulation.amount.carbohydrate"], with: "15")
        closeSimulationKeyboard(in: app)
        // The comparison rows follow the list; a Form creates rows lazily.
        let bolusRow = app.staticTexts["Bolus IOB, Basis, Szenario, Delta, 0.00 IE, 1.00 IE, +1.00 IE"]
        let carbohydrateRow = app.staticTexts["Aktive KH, Basis, Szenario, Delta, 0.00 g, 15.00 g, +15.00 g"]
        for row in [bolusRow, carbohydrateRow] {
            for _ in 0..<6 {
                if row.waitForExistence(timeout: 1) { break }
                scrollUpALittle(in: app)
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        }
        toolbarAction("Szenario speichern", in: app).tap()
        let savedScenario = app.staticTexts[scenarioName]
        // Repeated imports retain the same case and its saved scenarios. Form
        // virtualizes older/longer histories, so locate the appended row by scrolling.
        for _ in 0..<8 {
            if savedScenario.waitForExistence(timeout: 0.5) { break }
            app.swipeUp()
        }
        XCTAssertTrue(savedScenario.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Schließen"].tap()
        XCTAssertEqual(metric("Basal IOB", in: app).label, correctedLabel)
        XCTAssertEqual(metric("Bolus IOB", in: app).label, "Bolus IOB, 0.00, IE")
        XCTAssertEqual(metric("Aktive KH", in: app).label, "Aktive KH, 0.00, g")

        // Removing the basal amount withholds basal and total IOB, simulations
        // and the decay charts until a further immutable revision restores it.
        // Bolus IOB and active carbohydrates rest on complete data and stay.
        app.buttons["Korrigieren"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5), app.debugDescription)
        replace(amount, with: "")
        app.buttons["Revision speichern"].tap()
        let unavailable = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Basal IOB, Nicht verfügbar"
        )).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10), app.debugDescription)
        for title in ["Basal IOB", "Gesamt IOB"] {
            XCTAssertTrue(metric(title, in: app).label.contains("Nicht verfügbar"))
        }
        XCTAssertEqual(metric("Bolus IOB", in: app).label, "Bolus IOB, 0.00, IE")
        XCTAssertEqual(metric("Aktive KH", in: app).label, "Aktive KH, 0.00, g")
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

    /// The keyboard covers the lower rows; its "Fertig" key closes it.
    private func closeSimulationKeyboard(in app: XCUIApplication) {
        let done = app.buttons["simulation.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// Opens the add menu of the simulation's event list and picks an entry.
    private func addSimulationEvent(_ title: String, in app: XCUIApplication) {
        let add = app.buttons["simulation.addEvent"]
        for _ in 0..<6 {
            if add.waitForExistence(timeout: 1), add.isHittable { break }
            scrollUpALittle(in: app)
        }
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        // Tap the label at the leading edge: the row is wider than the menu's text.
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let entry = app.buttons[title]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }

    /// A short drag, so a row just below the fold is not scrolled past.
    private func scrollUpALittle(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
    }

    private func replace(_ field: XCUIElement, with value: String) {
        if field.identifier.hasPrefix("simulation.") {
            // An element tap scrolls the field into view first.
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        }
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + value)
    }
}
