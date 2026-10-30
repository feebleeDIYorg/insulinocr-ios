import CoreGraphics
import CoreText
import Foundation
import ImageIO
import InsulinOCRCore
import XCTest

@MainActor
final class NativeAnalysisFailureTests: XCTestCase {
    func testRejectedLayoutRetainsActualVisionObservations() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1200,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let text = NSAttributedString(string: "02:00", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 120, y: 600)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let request = ScreenshotAnalysisRequest(imageData: bytes as Data)
        let result = await NativeAnalysisEngine().analyzeRetainingFailure(request)
        guard case .failure(let failure) = result else { return XCTFail("Portrait layout accepted") }
        XCTAssertEqual(failure.code, .unsupportedLayout, failure.message)
        XCTAssertEqual(failure.requestID, request.id)
        XCTAssertTrue(failure.rawTextObservations.contains {
            $0.region == .fullImage && $0.candidates.contains { $0.text == "02:00" }
        }, failure.message)
    }

}
