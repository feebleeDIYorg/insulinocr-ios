import Foundation
import InsulinOCRCore
import XCTest

/// Runs the real extractor, including Vision pill OCR, on the synthetic chart
/// that carries one carbohydrate and one bolus event. Synthetic pixels only:
/// this is not evidence for recognition accuracy on real screenshots.
@MainActor
final class SyntheticEventAnalysisTests: XCTestCase {
    func testSyntheticEventsAreRecognizedEndToEnd() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "SyntheticTherapyEvents12Hours", withExtension: "png", subdirectory: "Fixtures"))
        let result = try await NativeAnalysisEngine().analyze(ScreenshotAnalysisRequest(
            imageData: try Data(contentsOf: fixture), timeZoneIdentifier: "Europe/Zurich"))

        let events = result.therapyEvents.sorted { $0.date < $1.date }
        let diagnostics = events.map { event in
            let texts = event.candidates
                .map { "\($0.text)@\(String(format: "%.2f", $0.confidence))" }
                .joined(separator: "|")
            return "\(event.kind.rawValue) \(event.date) \(event.amount) [\(texts)]"
        }.joined(separator: "; ")
        let warnings = result.warnings.map(\.code.rawValue).joined(separator: ",")
        let context = "events: \(diagnostics); warnings: \(warnings)"

        // Fixture clock: EXIF capture 2026-01-02 12:00 Europe/Zurich (11:00 UTC).
        let formatter = ISO8601DateFormatter()
        let expected: [(kind: OCRTherapyEventKind, amount: Double, date: Date)] = [
            (.carbohydrates, 24, try XCTUnwrap(formatter.date(from: "2026-01-02T02:00:00Z"))),
            (.bolus, 4, try XCTUnwrap(formatter.date(from: "2026-01-02T06:00:00Z")))
        ]
        XCTAssertEqual(events.count, expected.count, context)
        for (event, reference) in zip(events, expected) {
            XCTAssertEqual(event.kind, reference.kind, context)
            XCTAssertEqual(event.amount, .known(reference.amount), context)
            XCTAssertEqual(event.date.timeIntervalSince(reference.date), 0, accuracy: 180, context)
            XCTAssertTrue(event.isCompleteStem, context)
        }

        XCTAssertEqual(result.quality.completeEventStemCount, 2, context)
        XCTAssertEqual(result.quality.unknownEventAmountCount, 0, context)
        XCTAssertFalse(result.warnings.contains {
            $0.code == .eventAmountUnknown || $0.code == .eventKindUnknown
        }, context)
        XCTAssertEqual(result.status, .complete, context)

        // The event stems must not disturb the basal path or the glucose trace.
        XCTAssertFalse(result.basalSteps.isEmpty)
        for step in result.basalSteps {
            XCTAssertEqual(try XCTUnwrap(step.rateUnitsPerHour), 0.8, accuracy: 0.05)
        }
        XCTAssertFalse(result.glucoseSamples.isEmpty)
    }
}
