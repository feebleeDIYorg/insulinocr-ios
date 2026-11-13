import XCTest
@testable import InsulinOCRCore

final class ObservationCropRegionTests: XCTestCase {
    func testEventRegionIncludesThePillAboveTheStemTop() throws {
        // Stem as the detector reports it: thin, ending in the lower label row.
        let stem = NormalizedBoundingBox(x: 0.5, y: 0.178, width: 0.0012, height: 0.06)
        for kind in [ObservationKind.bolus, .carbohydrate, .eventStem] {
            let region = try XCTUnwrap(ObservationCropRegion.region(for: kind, boundingBox: stem))
            XCTAssertEqual(region.x, 0.4306, accuracy: 1e-9)
            XCTAssertEqual(region.width, 0.14, accuracy: 1e-9)
            XCTAssertEqual(region.y, 0.113, accuracy: 1e-9)
            XCTAssertEqual(region.height, 0.1, accuracy: 1e-9)
            XCTAssertTrue(region.isValid)
            // The stem is marked inside the crop, clipped at its lower edge.
            let mark = try XCTUnwrap(ObservationCropRegion.highlight(of: stem, in: region))
            XCTAssertEqual(mark.y, 0.65, accuracy: 1e-9)
            XCTAssertEqual(mark.y + mark.height, 1, accuracy: 1e-9)
            XCTAssertEqual(mark.x + mark.width / 2, 0.5, accuracy: 1e-9)
        }
    }

    func testRegionIsClampedToTheImageAndNeedsMeasuredGeometry() throws {
        let corner = NormalizedBoundingBox(x: 0.99, y: 0.02, width: 0.002, height: 0.05)
        let region = try XCTUnwrap(ObservationCropRegion.region(for: .bolus, boundingBox: corner))
        XCTAssertEqual(region.y, 0)
        XCTAssertEqual(region.x + region.width, 1, accuracy: 1e-9)
        XCTAssertTrue(region.isValid)
        // A manually added data point has no geometry and therefore no crop.
        XCTAssertNil(ObservationCropRegion.region(
            for: .bolus, boundingBox: .init(x: 0, y: 0, width: 0, height: 0)))
        XCTAssertNil(ObservationCropRegion.region(
            for: .glucose, boundingBox: .init(x: 0.5, y: 0.5, width: .nan, height: 0.1)))
    }

    func testBasalAndGlucoseKeepContextAroundTheirGeometry() throws {
        let step = NormalizedBoundingBox(x: 0.3, y: 0.6, width: 0.05, height: 0.01)
        let region = try XCTUnwrap(ObservationCropRegion.region(for: .basalRate, boundingBox: step))
        XCTAssertEqual(region.x, 0.26, accuracy: 1e-9)
        XCTAssertEqual(region.width, 0.13, accuracy: 1e-9)
        XCTAssertEqual(region.y, 0.54, accuracy: 1e-9)
        XCTAssertEqual(region.height, 0.13, accuracy: 1e-9)
        XCTAssertNil(ObservationCropRegion.highlight(
            of: .init(x: 0.8, y: 0.1, width: 0.01, height: 0.01), in: region))
    }
}
