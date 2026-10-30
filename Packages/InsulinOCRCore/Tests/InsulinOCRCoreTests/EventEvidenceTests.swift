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
}
