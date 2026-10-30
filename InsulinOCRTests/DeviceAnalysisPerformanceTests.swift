import Foundation
import ImageIO
import InsulinOCRCore
import XCTest

@MainActor
final class DeviceAnalysisPerformanceTests: XCTestCase {
    func testSyntheticScreenshotAnalysisP95OnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The release latency gate requires the physical target iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["INSULINOCR_DEVICE_BENCHMARK"] == "1" else {
            throw XCTSkip("Run explicitly on the physical target; no ordinary test run starts a benchmark.")
        }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "SyntheticTherapy12Hours", withExtension: "png", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: fixture)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2622)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1206)
        var durations: [Double] = []
        var versions = Set<String>()
        for _ in 0..<20 {
            let engine = NativeAnalysisEngine()
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await engine.analyze(ScreenshotAnalysisRequest(
                imageData: data, timeZoneIdentifier: "Europe/Zurich"))
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            versions.insert(result.algorithmVersion)
            XCTAssertFalse(result.rawTextObservations.isEmpty)
            XCTAssertFalse(result.basalSteps.isEmpty)
            XCTAssertFalse(result.glucoseSamples.isEmpty)
        }
        let ordered = durations.sorted()
        let p95 = ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1]
        let report = Report(sampleCount: durations.count, width: 2622, height: 1206,
                            p95Seconds: p95, maximumSeconds: ordered.last ?? 0,
                            durationsSeconds: durations, algorithmVersions: versions.sorted())
        let attachment = XCTAttachment(data: try JSONEncoder().encode(report), uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-device-analysis-performance.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(p95, 10, "Physical-device OCR P95 exceeds the release gate.")
        #endif
    }

    private struct Report: Encodable {
        let sampleCount: Int
        let width: Int
        let height: Int
        let p95Seconds: Double
        let maximumSeconds: Double
        let durationsSeconds: [Double]
        let algorithmVersions: [String]
    }
}
