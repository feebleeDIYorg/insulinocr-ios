import Foundation
import InsulinOCRCore
import XCTest
@testable import InsulinOCR

@MainActor final class TimestampPrecisionTests: XCTestCase {
    private struct Payload: Codable { let date: Date }

    func testFractionalTimestampsRoundTripWithinOneNanosecond() throws {
        for interval in [800_000_000.1234567, -0.1234567894, 0, 800_000_000.9999999] {
            let date = Date(timeIntervalSinceReferenceDate: interval)
            let restored = try JSONDecoder.insulinOCR.decode(Payload.self,
                from: JSONEncoder.insulinOCR.encode(Payload(date: date)))
            XCTAssertEqual(restored.date.timeIntervalSince(date), 0, accuracy: 1e-9)
        }
    }

    func testLegacyWholeSecondsAndFractionalOffsetsRemainReadable() throws {
        let old = Data(#"{"date":"2026-01-15T12:00:00Z"}"#.utf8)
        XCTAssertEqual(try JSONDecoder.insulinOCR.decode(Payload.self, from: old).date.ISO8601Format(), "2026-01-15T12:00:00Z")
        let offset = Data(#"{"date":"2026-01-15T12:00:00.125+02:00"}"#.utf8)
        let actual = try JSONDecoder.insulinOCR.decode(Payload.self, from: offset).date
        let expected = try Date.ISO8601FormatStyle().parse("2026-01-15T10:00:00Z").addingTimeInterval(0.125)
        XCTAssertEqual(actual, expected)
        for value in ["2026-01-15T12:00:00.xZ", "2026-01-15T12:00:00.1234567890Z"] {
            XCTAssertThrowsError(try JSONDecoder.insulinOCR.decode(Payload.self,
                from: Data("{\"date\":\"\(value)\"}".utf8)))
        }
    }

    func testCorrectionKeepsExactGapBoundariesAfterPersistence() throws {
        let end = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567)
        let start = end.addingTimeInterval(-1.25)
        let observation = RawObservation(kind: .basalRate, startDate: start, endDate: end,
            amount: 0, unit: .unitsPerHour, amountState: .known,
            boundingBox: .init(x: 0, y: 0, width: 0, height: 0),
            confidence: .init(overall: 1, geometry: 0, recognition: 1, calibration: 1), provenance: .userCorrection)
        let revision = CorrectionRevision(caseID: UUID(), analysisRunID: UUID(), operations: [.add(observation)])
        let restored = try JSONDecoder.insulinOCR.decode(CorrectionRevision.self,
            from: JSONEncoder.insulinOCR.encode(revision))
        XCTAssertEqual(restored, revision)
        guard case .add(let entry) = restored.operations[0] else { return XCTFail("Missing correction") }
        XCTAssertEqual(entry.startDate, start)
        XCTAssertEqual(entry.endDate, end)
    }
}
