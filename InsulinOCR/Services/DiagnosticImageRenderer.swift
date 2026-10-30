import CoreGraphics
import Foundation
import ImageIO
import InsulinOCRCore
import UniformTypeIdentifiers

/// Produces a QA-only overlay while leaving the original screenshot bytes untouched.
actor DiagnosticImageRenderer {
    enum RenderError: LocalizedError {
        case invalidImage
        case contextCreationFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                "Das Diagnosebild konnte nicht aus dem Screenshot erzeugt werden."
            case .contextCreationFailed:
                "Der Grafikkontext für das Diagnosebild konnte nicht angelegt werden."
            case .encodingFailed:
                "Das Diagnosebild konnte nicht als PNG gespeichert werden."
            }
        }
    }

    func render(originalData: Data, result: OCRAnalysisResult) throws -> Data {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderError.invalidImage
        }
        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RenderError.contextCreationFailed
        }

        // Work in the top-left coordinate system also used by Vision/domain boxes.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        stroke(
            result.layout.plotFrame,
            color: CGColor(red: 0.1, green: 0.75, blue: 0.25, alpha: 0.95),
            width: 4,
            context: context,
            imageWidth: width,
            imageHeight: height
        )

        for observation in result.rawTextObservations {
            stroke(
                observation.boundingBox,
                color: CGColor(red: 1, green: 0.78, blue: 0, alpha: 0.8),
                width: 2,
                context: context,
                imageWidth: width,
                imageHeight: height
            )
        }

        for sample in result.glucoseSamples {
            let color = sample.mmolPerLiter == nil
                ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.95)
                : CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 0.95)
            stroke(
                sample.boundingBox,
                color: color,
                width: 3,
                context: context,
                imageWidth: width,
                imageHeight: height
            )
        }

        for event in result.therapyEvents {
            let color = switch event.kind {
            case .bolus:
                CGColor(red: 0.24, green: 0.18, blue: 0.72, alpha: 0.95)
            case .carbohydrates:
                CGColor(red: 0.95, green: 0.42, blue: 0.05, alpha: 0.95)
            case .unknown:
                CGColor(red: 0.9, green: 0.08, blue: 0.12, alpha: 0.95)
            }
            stroke(
                event.stemBoundingBox,
                color: color,
                width: 5,
                context: context,
                imageWidth: width,
                imageHeight: height
            )
            stroke(
                event.pillBoundingBox,
                color: color,
                width: 3,
                context: context,
                imageWidth: width,
                imageHeight: height
            )
        }

        drawBasalPath(
            result.basalSteps,
            result: result,
            context: context,
            imageWidth: width,
            imageHeight: height
        )

        guard let rendered = context.makeImage(),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw RenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.encodingFailed
        }
        return output as Data
    }

    private func drawBasalPath(
        _ steps: [OCRBasalStep],
        result: OCRAnalysisResult,
        context: CGContext,
        imageWidth: Int,
        imageHeight: Int
    ) {
        guard !steps.isEmpty, result.timeCalibration.slope != 0 else { return }
        let referenceAxisValue = result.timeCalibration.value(at: result.layout.dataRightEdgeX)
        context.setStrokeColor(CGColor(red: 0.05, green: 0.36, blue: 0.96, alpha: 0.95))
        context.setLineWidth(4)

        for step in steps {
            let startX = normalizedX(
                date: step.startDate,
                referenceDate: result.timeAxisReferenceDate ?? result.capturedAt,
                referenceAxisValue: referenceAxisValue,
                calibration: result.timeCalibration
            )
            let endX = normalizedX(
                date: step.endDate,
                referenceDate: result.timeAxisReferenceDate ?? result.capturedAt,
                referenceAxisValue: referenceAxisValue,
                calibration: result.timeCalibration
            )
            context.move(
                to: CGPoint(
                    x: startX * Double(imageWidth),
                    y: step.pixelY * Double(imageHeight)
                )
            )
            context.addLine(
                to: CGPoint(
                    x: endX * Double(imageWidth),
                    y: step.pixelY * Double(imageHeight)
                )
            )
        }
        context.strokePath()
    }

    private func normalizedX(
        date: Date,
        referenceDate: Date,
        referenceAxisValue: Double,
        calibration: OCRAxisCalibration
    ) -> Double {
        let axisValue = referenceAxisValue + date.timeIntervalSince(referenceDate) / 60
        return (axisValue - calibration.intercept) / calibration.slope
    }

    private func stroke(
        _ normalizedRect: OCRNormalizedRect,
        color: CGColor,
        width: CGFloat,
        context: CGContext,
        imageWidth: Int,
        imageHeight: Int
    ) {
        let rect = CGRect(
            x: normalizedRect.x * Double(imageWidth),
            y: normalizedRect.y * Double(imageHeight),
            width: normalizedRect.width * Double(imageWidth),
            height: normalizedRect.height * Double(imageHeight)
        )
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.stroke(rect)
    }
}
