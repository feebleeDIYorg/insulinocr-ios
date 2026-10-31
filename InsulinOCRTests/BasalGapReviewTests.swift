import Foundation
import XCTest
@testable import InsulinOCR

@MainActor final class BasalGapReviewTests: XCTestCase {
    func testExactFractionalTrailingGapIsPreservedWithoutRounding() {
        let end = Date(timeIntervalSince1970: 1_800_000_000.75)
        let window = DateInterval(start: end.addingTimeInterval(-3600), end: end)
        let gapStart = end.addingTimeInterval(-1.25)
        let result = BasalGapReview.gaps(intervals: [.init(start: window.start, end: gapStart)], in: window)
        XCTAssertEqual(result, [.init(start: gapStart, end: end)])
        XCTAssertEqual(result[0].duration, 1.25, accuracy: 1e-9)
    }

    func testLeadingInteriorAndTrailingGapsUseOnlyExplicitIntervalBounds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let date: (Double) -> Date = { start.addingTimeInterval($0) }
        let result = BasalGapReview.gaps(intervals: [.init(start: date(10), end: date(20)),
            .init(start: date(30), end: date(40))], in: .init(start: start, end: date(50)))
        XCTAssertEqual(result, [.init(start: start, end: date(10)),
            .init(start: date(20), end: date(30)), .init(start: date(40), end: date(50))])
    }
}
