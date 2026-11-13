import XCTest
@testable import InsulinOCRCore

final class EventEvidenceTests: XCTestCase {
    private func stem(x: Double = 0.4) -> OCRDetectedEventStem {
        .init(kind: .unknown,
              stemRect: .init(x: x, y: 0.2, width: 0.002, height: 0.05),
              pillRect: .init(x: x - 0.04, y: 0.15, width: 0.08, height: 0.05),
              isComplete: true, confidence: 0.9)
    }
    private func observation(_ text: String, confidence: Double = 0.8,
                             x: Double = 0.38, width: Double = 0.04) -> OCRRawTextObservation {
        .init(region: .fullImage,
              boundingBox: .init(x: x, y: 0.16, width: width, height: 0.025),
              candidates: [.init(text: text, confidence: confidence)])
    }

    func testUncroppedEvidenceRecoversAnOtherwiseUnknownAmount() {
        let event = stem(), full = observation("23 g")
        let evidence = OCRObservationInterpreter.eventTextEvidence(from: [full], for: event, among: [event])
        let crop = OCRTextCandidate(text: "23 9", confidence: 0.3)
        let parsed = OCRTextParser.amount(from: [crop] + evidence.flatMap(\.candidates), expectedKind: .unknown)
        XCTAssertEqual(parsed.0, .known(23))
        XCTAssertEqual(parsed.1, .carbohydrates)
        XCTAssertEqual(evidence.map(\.id), [full.id])
    }

    func testSharedOrClippedEvidenceCannotBeAssigned() {
        let event = stem(), duplicate = stem(x: 0.41), full = observation("23 g")
        XCTAssertTrue(OCRObservationInterpreter.eventTextEvidence(from: [full], for: event, among: [event, duplicate]).isEmpty)
        let crossing = observation("23 g 47 g", x: 0.38, width: 0.12)
        XCTAssertTrue(OCRObservationInterpreter.eventTextEvidence(from: [crossing], for: event, among: [event]).isEmpty)
        let neighbour = observation("47 g", x: 0.42, width: 0.015)
        XCTAssertTrue(OCRObservationInterpreter.eventTextEvidence(from: [neighbour], for: event, among: [event]).isEmpty)
    }

    func testConfidenceAndConflictingAmountsRemainFailClosed() {
        let event = stem()
        let low = observation("23 g", confidence: 0.3)
        let weak = OCRObservationInterpreter.eventTextEvidence(from: [low], for: event, among: [event])
        XCTAssertEqual(OCRTextParser.amount(from: weak.flatMap(\.candidates), expectedKind: .unknown).0, .amountUnknown)
        let conflict = [OCRTextCandidate(text: "24 g", confidence: 0.9)] + observation("23 g").candidates
        XCTAssertEqual(OCRTextParser.amount(from: conflict, expectedKind: .unknown).0, .amountUnknown)
    }

    func testUnitOfTheOtherKindContradictsTheLabelRow() {
        func text(_ value: String, _ confidence: Double = 1) -> [OCRTextCandidate] {
            [.init(text: value, confidence: confidence)]
        }
        // An upper-row pill reading grams, or a lower-row pill reading units.
        XCTAssertTrue(OCRTextParser.unitContradicts(text("46 g"), expectedKind: .bolus))
        XCTAssertTrue(OCRTextParser.unitContradicts(text("4.8 IE"), expectedKind: .carbohydrates))
        // Agreement, no readable unit, weak text and unknown kind are no contradiction.
        XCTAssertFalse(OCRTextParser.unitContradicts(text("4.8 IE"), expectedKind: .bolus))
        XCTAssertFalse(OCRTextParser.unitContradicts(text("4.8"), expectedKind: .carbohydrates))
        XCTAssertFalse(OCRTextParser.unitContradicts(text("160"), expectedKind: .bolus))
        XCTAssertFalse(OCRTextParser.unitContradicts(text("46 g", 0.3), expectedKind: .bolus))
        XCTAssertFalse(OCRTextParser.unitContradicts(text("46 g"), expectedKind: .unknown))
        XCTAssertFalse(OCRTextParser.unitContradicts([], expectedKind: .bolus))
        // A row-assigned kind never borrows the other kind's amount.
        XCTAssertNil(OCRTextParser.amount(from: text("46 g"), expectedKind: .bolus).0.value)
    }

    func testAgreeingLowConfidencePassesCorroborateAnAmount() {
        func pass(_ texts: String..., confidence: Double = 0.3) -> [OCRTextCandidate] {
            texts.map { .init(text: $0, confidence: confidence) }
        }
        let carbs = OCRTextParser.corroboratedAmount(
            fromPasses: [pass("24g"), [], pass("24 g")], expectedKind: .unknown)
        XCTAssertEqual(carbs.0, .known(24))
        XCTAssertEqual(carbs.1, .carbohydrates)
        XCTAssertEqual(carbs.2, 0.3, accuracy: 1e-9)
        XCTAssertEqual(OCRTextParser.corroboratedAmount(
            fromPasses: [pass("2IE"), pass("2 IE")], expectedKind: .unknown).1, .bolus)

        // One pass alone, even with two readings, is not corroboration.
        let unknown = OCRDetectedAmount.amountUnknown
        XCTAssertEqual(OCRTextParser.corroboratedAmount(
            fromPasses: [pass("24g", "24 g"), []], expectedKind: .unknown).0, unknown)
        // Any deviating, unreadable or kind-contradicting reading is a veto.
        for other in [pass("4g"), pass("24"), pass("24 IE"), pass("24g", "Z4g"),
                      pass("24g", confidence: 0.1)] {
            XCTAssertEqual(OCRTextParser.corroboratedAmount(
                fromPasses: [pass("24g"), other], expectedKind: .unknown).0, unknown)
        }
        XCTAssertEqual(OCRTextParser.corroboratedAmount(
            fromPasses: [pass("24g"), pass("24 g")], expectedKind: .bolus).0, unknown)
    }
}
