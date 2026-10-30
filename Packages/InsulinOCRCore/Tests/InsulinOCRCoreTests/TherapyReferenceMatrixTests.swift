import Foundation
import XCTest
@testable import InsulinOCRCore

final class TherapyReferenceMatrixTests: XCTestCase {
    private struct GoldenFile: Decodable {
        let sourceSHA256: String
        let vectors: [[Double]]
    }

    func testAllInsulinSettingsAgainstPinnedOpenAPSImplementation() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "OpenAPSInsulinGoldens", withExtension: "json"))
        let fixture = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.sourceSHA256, "ca8b738cd5c4db037760949c09028448e01b155680f0bac6c3c081e24300d348")
        XCTAssertEqual(fixture.vectors.count, 1_620)
        XCTAssertEqual(Set(fixture.vectors.map { Int($0[0]) }), Set(stride(from: 180, through: 600, by: 30)))
        XCTAssertEqual(Set(fixture.vectors.map { $0[1] }), Set(InsulinType.allCases.map(\.peakMinutes)))
        for row in fixture.vectors {
            guard row.count == 5 else { XCTFail("Malformed golden vector"); continue }
            let actual = InsulinActivityModel.remainingUnits(units: row[3], minutes: row[2],
                durationMinutes: row[0], peakMinutes: row[1])
            XCTAssertEqual(actual, row[4], accuracy: 1e-9,
                "DIA=\(row[0]), peak=\(row[1]), age=\(row[2]), units=\(row[3])")
        }
    }

    func testMinuteBasalFoldAgainstTenSecondReferenceForEveryInsulinSetting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let segments = [
            BasalSegment(startDate: now.addingTimeInterval(-43_200 + 17.25),
                endDate: now.addingTimeInterval(-14_400 + 37.75), unitsPerHour: 3.2),
            BasalSegment(startDate: now.addingTimeInterval(-14_400 + 37.75),
                endDate: now.addingTimeInterval(-4_380 + 11.5), unitsPerHour: 0.05),
            BasalSegment(startDate: now.addingTimeInterval(-2_460 + 23.25),
                endDate: now.addingTimeInterval(16.5), unitsPerHour: 20),
        ]
        let calculator = DefaultActivityCalculator()
        for dia in stride(from: 180, through: 600, by: 30) {
            for insulin in InsulinType.allCases {
                let minute = calculator.basalIOB(segments: segments, at: now,
                    durationMinutes: Double(dia), peakMinutes: insulin.peakMinutes,
                    integrationStepSeconds: 60)
                let reference = calculator.basalIOB(segments: segments, at: now,
                    durationMinutes: Double(dia), peakMinutes: insulin.peakMinutes,
                    integrationStepSeconds: 10)
                XCTAssertLessThanOrEqual(abs(minute - reference), 0.005,
                    "DIA=\(dia), insulin=\(insulin.rawValue)")
            }
        }
    }

    func testCarbohydrateBoundariesForEverySupportedAbsorptionDuration() {
        for duration in stride(from: 120, through: 480, by: 30) {
            for grams in [0.05, 1, 60, 150] {
                let points: [(Double, Double)] = [
                    (0, 1), (10, 1),
                    (10 + 0.15 * Double(duration), 8.0 / 9),
                    (10 + 0.5 * Double(duration), 10.0 / 27),
                    (10 + Double(duration), 0), (11 + Double(duration), 0),
                ]
                for (age, fraction) in points {
                    XCTAssertEqual(CarbohydrateAbsorptionModel.remainingGrams(grams: grams,
                        minutes: age, absorptionDurationMinutes: Double(duration)),
                        grams * fraction, accuracy: 1e-9,
                        "Absorption=\(duration), age=\(age), grams=\(grams)")
                }
            }
        }
    }

    func testEveryInsulinCurveIsBoundedAndMonotonicAtMinuteResolution() {
        for dia in stride(from: 180, through: 600, by: 30) {
            for insulin in InsulinType.allCases {
                var previous = 1.0
                for age in 0...dia {
                    let remaining = InsulinActivityModel.remainingUnits(units: 1,
                        minutes: Double(age), durationMinutes: Double(dia), peakMinutes: insulin.peakMinutes)
                    XCTAssertTrue(remaining.isFinite)
                    XCTAssertGreaterThanOrEqual(remaining, 0)
                    XCTAssertLessThanOrEqual(remaining, previous + 1e-12)
                    previous = remaining
                }
                XCTAssertEqual(previous, 0, accuracy: 1e-12)
            }
        }
    }
}
