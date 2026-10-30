import Foundation
import XCTest
@testable import InsulinOCR

@MainActor
final class AppSettingsTests: XCTestCase {
    func testOnboardingSelectionPersistsAndProducesVersionedSnapshot() throws {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.onboardingComplete)
        XCTAssertEqual(settings.diaMinutes, 360)
        XCTAssertEqual(settings.carbAbsorptionMinutes, 240)
        XCTAssertFalse(settings.iCloudEnabled)

        settings.completeOnboarding(diaMinutes: 450, insulinPreset: .lyumjev)
        settings.carbAbsorptionMinutes = 300

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.onboardingComplete)
        XCTAssertEqual(restored.diaMinutes, 450)
        XCTAssertEqual(restored.insulinPreset, .lyumjev)
        XCTAssertEqual(restored.snapshot.insulinPeakMinutes, 45)
        XCTAssertEqual(restored.snapshot.carbDelayMinutes, 10)
        XCTAssertEqual(restored.snapshot.carbAbsorptionMinutes, 300)
    }
}
