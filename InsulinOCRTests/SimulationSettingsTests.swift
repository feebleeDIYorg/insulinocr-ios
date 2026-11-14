import Foundation
import InsulinOCRCore
import XCTest
@testable import InsulinOCR

@MainActor
final class SimulationSettingsTests: XCTestCase {
    func testSimulationSettingsStartEmptyAndPersist() throws {
        let suiteName = "SimulationSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        // No sensitivity or carbohydrate ratio is assumed, and no preset is invented.
        XCTAssertNil(settings.simulation.sensitivity)
        XCTAssertNil(settings.simulation.carbRatio)
        XCTAssertTrue(settings.simulation.activityPresets.isEmpty)
        XCTAssertEqual(settings.simulation.limits, GlucoseLimits())
        XCTAssertEqual(settings.simulation.limits.hypo, 3.9)
        XCTAssertEqual(settings.simulation.limits.targetHigh, 10)
        XCTAssertEqual(settings.simulation.model, .loop)

        let sensitivity = try DailyProfile(blocks: [
            .init(startMinute: 0, value: 2.5), .init(startMinute: 420, value: 1.8),
        ])
        settings.simulation.sensitivity = sensitivity
        settings.simulation.carbRatio = try DailyProfile(constant: 10)
        settings.simulation.activityPresets = [
            ActivityPreset(name: "Joggen", insulinNeedPercent: 70, durationMinutes: 240),
        ]
        settings.simulation.limits = GlucoseLimits(hypo: 3.5, targetLow: 4.5, targetHigh: 8, hyper: 11)
        settings.simulation.model = .oref

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.simulation, settings.simulation)
        XCTAssertEqual(restored.simulation.sensitivity, sensitivity)
        XCTAssertEqual(restored.simulation.activityPresets.first?.name, "Joggen")

        // Unreadable stored data never blocks the app: defaults are used.
        defaults.set(Data("not json".utf8), forKey: "settings.simulation")
        XCTAssertEqual(AppSettings(defaults: defaults).simulation, SimulationSettings())
    }

    func testStoredInvalidPresetsAndLimitsAreDropped() throws {
        let json = """
        {"activityPresets":[{"id":"\(UUID().uuidString)","name":"","insulinNeedPercent":70,"durationMinutes":60},
        {"id":"\(UUID().uuidString)","name":"Rad","insulinNeedPercent":80,"durationMinutes":120}],
        "limits":{"hypo":9,"targetLow":4,"targetHigh":8,"hyper":10}}
        """
        let decoded = try JSONDecoder().decode(SimulationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activityPresets.map(\.name), ["Rad"])
        XCTAssertEqual(decoded.limits, GlucoseLimits())
        XCTAssertEqual(decoded.model, .loop)
    }

    func testLimitsAndPresetsAreValidated() {
        XCTAssertTrue(GlucoseLimits().isValid)
        XCTAssertTrue(GlucoseLimits(hypo: 3.5, targetLow: 4.5, targetHigh: 8, hyper: 11).isValid)
        for limits in [
            GlucoseLimits(hypo: 5, targetLow: 4.5, targetHigh: 8, hyper: 11),
            GlucoseLimits(hypo: 3.5, targetLow: 8, targetHigh: 8, hyper: 11),
            GlucoseLimits(hypo: 3.5, targetLow: 4.5, targetHigh: 8, hyper: 7),
            GlucoseLimits(hypo: 1, targetLow: 4.5, targetHigh: 8, hyper: 11),
            GlucoseLimits(hypo: 3.5, targetLow: 4.5, targetHigh: 8, hyper: .nan),
        ] {
            XCTAssertFalse(limits.isValid)
        }
        XCTAssertTrue(ActivityPreset(name: "Joggen", insulinNeedPercent: 70, durationMinutes: 240).isValid)
        XCTAssertFalse(ActivityPreset(name: " ", insulinNeedPercent: 70, durationMinutes: 240).isValid)
        XCTAssertFalse(ActivityPreset(name: "Joggen", insulinNeedPercent: 5, durationMinutes: 240).isValid)
        XCTAssertFalse(ActivityPreset(name: "Joggen", insulinNeedPercent: 70, durationMinutes: 10).isValid)
    }

    func testProfileDraftConvertsUnitsAndRejectsIncompleteInput() throws {
        // A stored sensitivity in mmol/L is edited in mg/dl and stored back in mmol/L.
        let stored = try DailyProfile(blocks: [.init(startMinute: 0, value: 2), .init(startMinute: 360, value: 3)])
        var draft = DailyProfileDraft(profile: stored, displayScale: 18)
        XCTAssertEqual(draft.rows.map(\.text), ["36", "54"])
        let roundTrip = try XCTUnwrap(draft.profile(displayScale: 18, allowed: SimulationSettings.sensitivityRange))
        XCTAssertEqual(roundTrip.blocks.map(\.startMinute), [0, 360])
        XCTAssertEqual(roundTrip.blocks[0].value, 2, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.blocks[1].value, 3, accuracy: 1e-9)

        // A new block starts an hour after the latest and is empty: nothing to save yet.
        draft.addRow()
        XCTAssertEqual(draft.rows.last?.startMinute, 420)
        XCTAssertNil(draft.profile(displayScale: 18, allowed: SimulationSettings.sensitivityRange))
        draft.rows[2].text = "45,0"
        // Rows are saved in time order whatever order they were typed in.
        draft.rows[2].startMinute = 120
        let sorted = try XCTUnwrap(draft.profile(displayScale: 18, allowed: SimulationSettings.sensitivityRange))
        XCTAssertEqual(sorted.blocks.map(\.startMinute), [0, 120, 360])
        XCTAssertEqual(sorted.blocks[1].value, 2.5, accuracy: 1e-9)
        // Two blocks at the same time, or a value outside the allowed range, are not saved.
        draft.rows[2].startMinute = 360
        XCTAssertNil(draft.profile(displayScale: 18, allowed: SimulationSettings.sensitivityRange))
        draft.rows[2].startMinute = 120
        draft.rows[2].text = "0"
        XCTAssertNil(draft.profile(displayScale: 18, allowed: SimulationSettings.sensitivityRange))

        // Nothing stored yet: one empty block from midnight.
        let empty = DailyProfileDraft(profile: nil, displayScale: 1)
        XCTAssertEqual(empty.rows.map(\.startMinute), [0])
        XCTAssertNil(empty.profile(displayScale: 1, allowed: SimulationSettings.carbRatioRange))
        var late = DailyProfileDraft(rows: [.init(startMinute: 0, text: "10"), .init(startMinute: 1_400, text: "12")])
        XCTAssertFalse(late.canAddRow)
        late.addRow()
        XCTAssertEqual(late.rows.count, 2)
    }
}
