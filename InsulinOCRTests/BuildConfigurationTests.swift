import Foundation
import XCTest
@testable import InsulinOCR

final class BuildConfigurationTests: XCTestCase {
    func testAppUsesExpandedSharedGroupAndCloudConfiguration() throws {
        XCTAssertEqual(BuildConfiguration.appGroupIdentifier,
                       Bundle.main.object(forInfoDictionaryKey: "InsulinOCRAppGroup") as? String)
        XCTAssertEqual(BuildConfiguration.cloudKitContainerIdentifier,
                       Bundle.main.object(forInfoDictionaryKey: "InsulinOCRCloudKitContainer") as? String)
        XCTAssertFalse(BuildConfiguration.appGroupIdentifier.contains("$("))
        XCTAssertFalse(BuildConfiguration.cloudKitContainerIdentifier.contains("$("))
        XCTAssertNotNil(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BuildConfiguration.appGroupIdentifier))
    }
}
