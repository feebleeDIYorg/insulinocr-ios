import XCTest
@testable import InsulinOCRCore

final class ReviewSequenceTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), outside = UUID()

    func testStepsThroughTheFixedOrderAndStopsAtBothEnds() {
        let sequence = ReviewSequence(ids: [a, b, c, b])
        XCTAssertEqual(sequence.ids, [a, b, c])
        XCTAssertEqual(sequence.position(of: b), 1)
        XCTAssertNil(sequence.position(of: outside))
        XCTAssertNil(sequence.position(of: nil))
        let allOpen: (UUID) -> Bool = { _ in true }
        XCTAssertEqual(sequence.target(from: a, step: 1, isOpen: allOpen), b)
        XCTAssertEqual(sequence.target(from: c, step: -1, isOpen: allOpen), b)
        XCTAssertNil(sequence.target(from: c, step: 1, isOpen: allOpen))
        XCTAssertNil(sequence.target(from: a, step: -1, isOpen: allOpen))
        XCTAssertNil(sequence.target(from: a, step: 0, isOpen: allOpen))
    }

    func testConfirmedItemsStayReachableAndEntryPrefersAnOpenOne() {
        var sequence = ReviewSequence(ids: [a, b])
        let open: Set<UUID> = [b]
        // "a" was just filled in: it is still the previous item of "b".
        XCTAssertEqual(sequence.target(from: b, step: -1, isOpen: open.contains), a)
        XCTAssertEqual(sequence.openCount(isOpen: open.contains), 1)
        // From a data point outside the review, forward enters at the first open one.
        XCTAssertEqual(sequence.target(from: outside, step: 1, isOpen: open.contains), b)
        XCTAssertEqual(sequence.target(from: nil, step: 1, isOpen: { _ in false }), a)
        XCTAssertNil(sequence.target(from: outside, step: -1, isOpen: open.contains))
        sequence.append(c)
        sequence.append(a)
        XCTAssertEqual(sequence.ids, [a, b, c])
        XCTAssertNil(ReviewSequence().target(from: nil, step: 1, isOpen: { _ in true }))
        XCTAssertTrue(ReviewSequence().isEmpty)
    }
}
