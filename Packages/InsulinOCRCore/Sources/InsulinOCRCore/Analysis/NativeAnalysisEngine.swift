import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

public protocol AnalysisEngine: Sendable {
    func analyze(_ request: ScreenshotAnalysisRequest) async throws -> OCRAnalysisResult
}

public struct NativeAnalysisConfiguration: Sendable, Equatable {
    public let algorithmVersion: String
    public let minimumBasalCoverage: Double
    public let maximumTimeResidualMinutes: Double

    public init(
        algorithmVersion: String = "native-1.16.0",
        minimumBasalCoverage: Double = 0.99,
        maximumTimeResidualMinutes: Double = 1
    ) {
        self.algorithmVersion = algorithmVersion
        self.minimumBasalCoverage = minimumBasalCoverage
        self.maximumTimeResidualMinutes = maximumTimeResidualMinutes
    }
}

public actor NativeAnalysisEngine: AnalysisEngine {
    private let configuration: NativeAnalysisConfiguration
    private var latestObservations: [OCRRawTextObservation] = []

    public func diagnosticTextObservations() -> [OCRRawTextObservation] {
        latestObservations
    }

    public init(configuration: NativeAnalysisConfiguration = NativeAnalysisConfiguration()) {
        self.configuration = configuration
    }

    public func analyze(_ request: ScreenshotAnalysisRequest) async throws -> OCRAnalysisResult {
        do {
            return try analyzeUnchecked(request)
        } catch is CancellationError {
            throw OCRAnalysisFailure.cancelled
        }
    }

    /// Captures partial OCR before releasing this actor. The synchronous private
    /// pipeline cannot interleave another request between failure and snapshot.
    public func analyzeRetainingFailure(
        _ request: ScreenshotAnalysisRequest
    ) async -> Result<OCRAnalysisResult, OCRFailedAnalysis> {
        do {
            return .success(try analyzeUnchecked(request))
        } catch {
            let code: OCRFailedAnalysis.Code
            switch error {
            case OCRAnalysisFailure.invalidImage: code = .invalidImage
            case OCRAnalysisFailure.unsupportedLayout: code = .unsupportedLayout
            case OCRAnalysisFailure.invalidTimeAxis: code = .invalidTimeAxis
            case OCRAnalysisFailure.cancelled, is CancellationError: code = .cancelled
            default: code = .processingFailed
            }
            return .failure(OCRFailedAnalysis(
                requestID: request.id, algorithmVersion: configuration.algorithmVersion,
                visionRevision: Int(VNRecognizeTextRequestRevision3), code: code,
                message: error.localizedDescription, rawTextObservations: latestObservations,
                requestedCaptureTime: request.capturedAt, importedAt: request.importedAt,
                timeZoneIdentifier: request.timeZoneIdentifier))
        }
    }

    private func analyzeUnchecked(_ request: ScreenshotAnalysisRequest) throws -> OCRAnalysisResult {
        latestObservations = []
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithData(request.imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let pixelImage = Self.makePixelImage(from: cgImage) else {
            throw OCRAnalysisFailure.invalidImage
        }

        let captureMetadataDate = Self.captureDate(
            from: imageSource,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        let capturedAt = request.capturedAt ?? captureMetadataDate ?? request.importedAt
        let usedImportFallback = request.capturedAt == nil && captureMetadataDate == nil

        var rawObservations = try recognizeText(
            in: cgImage,
            region: OCRNormalizedRect(x: 0, y: 0, width: 1, height: 1),
            kind: .fullImage,
            minimumTextHeight: 0.006
        )
        latestObservations = rawObservations
        try Task.checkCancellation()

        let layoutEvidence = try OCRLayoutDetector.detect(
            image: pixelImage,
            observations: rawObservations
        )
        let frame = layoutEvidence.plotFrame
        let observedFrame = OCRNormalizedRect(x: frame.minX, y: frame.minY,
            width: layoutEvidence.dataRightEdgeX - frame.minX, height: frame.height)

        // Isolate tick labels from rotated axis titles and from tick strokes.
        // Vision otherwise prioritizes the title or reads a tick as a minus.
        let targetedRegions: [(OCRRegionKind, OCRNormalizedRect, Float)] = [
            (
                .timeAxis,
                OCRNormalizedRect(
                    x: frame.minX,
                    y: max(0, frame.maxY - 0.09),
                    width: frame.width,
                    height: min(1 - max(0, frame.maxY - 0.09), 0.18)
                ),
                0.012
            ),
            (
                .glucoseAxis,
                OCRNormalizedRect(
                    x: frame.maxX + 0.012,
                    y: frame.minY,
                    width: min(0.028, 1 - frame.maxX - 0.012),
                    height: frame.height
                ),
                0.015
            ),
            (
                .basalAxis,
                OCRNormalizedRect(
                    x: max(0, frame.minX - 0.035),
                    y: frame.minY,
                    width: min(frame.minX, 0.032),
                    height: frame.height
                ),
                0.015
            ),
        ]
        for (kind, region, minimumTextHeight) in targetedRegions {
            try Task.checkCancellation()
            rawObservations += try recognizeText(
                in: cgImage,
                region: region.clampedToUnitSquare(),
                kind: kind,
                minimumTextHeight: minimumTextHeight
            )
            latestObservations = rawObservations
        }

        latestObservations = rawObservations
        let stems = OCREventStemDetector.detect(image: pixelImage, plotFrame: observedFrame)
        let excludedStemRects = stems.map(\.stemRect)
        let markerCenters = OCRGlucoseExtractor.isolatedMarkerCentersX(
            image: pixelImage,
            plotFrame: observedFrame,
            excludedRects: excludedStemRects
        )
        let timeAnchors = OCRObservationInterpreter.timeAnchors(
            from: rawObservations,
            horizontalRange: frame.minX...frame.maxX
        )
        let timeCalibration = try TimeAxisCalibrator.calibrate(
            anchors: OCRLayoutDetector.alignTimeAnchors(timeAnchors, image: pixelImage, frame: frame,
                captureMarker: layoutEvidence.captureMarker),
            markerCentersX: markerCenters,
            plotRange: frame.minX...layoutEvidence.dataRightEdgeX
        )
        guard timeCalibration.maximumResidual <= configuration.maximumTimeResidualMinutes else {
            throw OCRAnalysisFailure.invalidTimeAxis(
                reason: "Time residual exceeds the configured threshold."
            )
        }

        let visibleHours = timeCalibration.slope
            * (layoutEvidence.dataRightEdgeX - frame.minX) / 60
        let supportedPartialWindow = layoutEvidence.captureMarker != nil
            && visibleHours > 0 && visibleHours < 0.95
            && (0.95...48.5).contains(timeCalibration.slope * frame.width / 60)
        guard (0.95...48.5).contains(visibleHours) || supportedPartialWindow else {
            throw OCRAnalysisFailure.unsupportedLayout(
                reason: "The visible window is outside the supported 1–48 hour range."
            )
        }
        let layout = OCRDetectedLayout(
            profile: .camAPSFXLandscapeV1,
            plotFrame: frame,
            dataRightEdgeX: layoutEvidence.dataRightEdgeX,
            estimatedVisibleHours: visibleHours,
            confidence: layoutEvidence.confidence,
            captureMarkerBounds: layoutEvidence.captureMarker
        )

        let leftAxisRange = 0...frame.minX
        let glucoseAnchors = OCRObservationInterpreter.numericAnchors(
            from: rawObservations,
            xRange: frame.maxX...1,
            yRange: frame.minY...frame.maxY,
            acceptedValues: 1...40
        )
        let basalAnchors = OCRObservationInterpreter.numericAnchors(
            from: rawObservations,
            xRange: leftAxisRange,
            yRange: frame.minY...frame.maxY,
            acceptedValues: 0...20
        )
        let glucoseCalibration = NumericAxisCalibrator.calibrate(
            kind: .glucose,
            anchors: OCRLayoutDetector.alignNumericAnchors(glucoseAnchors, image: pixelImage, frame: frame, kind: .glucose),
            allowedResidual: 0.25
        )
        let basalCalibration = NumericAxisCalibrator.calibrate(
            kind: .basalRate,
            anchors: OCRLayoutDetector.alignNumericAnchors(basalAnchors, image: pixelImage, frame: frame, kind: .basalRate),
            allowedResidual: 0.08
        )
        var timeline: OCRTimelineMapper
        let clockFailureReason: String?
        do {
            guard let timeZone = TimeZone(identifier: request.timeZoneIdentifier) else {
                throw OCRAnalysisFailure.invalidTimeAxis(reason: "Unknown capture time zone.")
            }
            timeline = try OCRTimelineMapper.clockAligned(calibration: timeCalibration,
                plotStartX: frame.minX, referenceX: layout.captureMarkerBounds?.maxX ?? layout.dataRightEdgeX,
                capturedAt: capturedAt, timeZone: timeZone)
            if layout.captureMarkerBounds != nil, abs(timeline.referenceDate.timeIntervalSince(capturedAt)) > 60 {
                throw OCRAnalysisFailure.invalidTimeAxis(reason: "Capture marker disagrees with capture clock by more than one minute.")
            }
            clockFailureReason = nil
        } catch OCRAnalysisFailure.invalidTimeAxis(let reason) {
            // Retain measured geometry/OCR for QA. Relative dates are explicitly
            // invalid for activity calculations until capture metadata is fixed.
            timeline = OCRTimelineMapper(calibration: timeCalibration,
                referenceX: layout.dataRightEdgeX, referenceDate: capturedAt)
            clockFailureReason = reason
        }
        // The capture marker is a zero-duration boundary, not missing therapy.
        // Its painted stroke and the future panel never enter pixel extraction.
        // Only a path touching its past edge may end at capture time, and only
        // when the independent clock agrees within one minute.
        let dataFrame = OCRNormalizedRect(
            x: frame.minX, y: frame.minY,
            width: layout.dataRightEdgeX - frame.minX, height: frame.height
        )

        let basal = OCRBasalPathExtractor.extract(
            image: pixelImage,
            plotFrame: dataFrame,
            excludedRects: excludedStemRects,
            timeline: timeline,
            rateCalibration: basalCalibration,
            captureMarkerEndDate: clockFailureReason == nil && layout.captureMarkerBounds != nil ? capturedAt : nil
        )
        let glucose = OCRGlucoseExtractor.extract(
            image: pixelImage,
            plotFrame: dataFrame,
            excludedRects: excludedStemRects,
            timeline: timeline,
            glucoseCalibration: glucoseCalibration,
            visibleMinutes: visibleHours * 60
        )

        var therapyEvents: [OCRTherapyEvent] = []
        for stem in stems where stem.isComplete {
            try Task.checkCancellation()
            // A pill is drawn above the plot frame, so the capture rule never
            // paints over it. One estimated to cross the boundary is read only
            // when its outline is measured closed; otherwise it stays unknown.
            let crossesBoundary = stem.pillRect.maxX > layout.dataRightEdgeX
            // Overlapping pills share pixels: a crop split between two stems
            // can cut a leading digit ("80 g" read as "30 g").
            let hasNeighbour = OCREventStemDetector.hasCompetingNeighbour(stem, among: stems)
            let measuredPill = crossesBoundary || hasNeighbour
                ? OCREventStemDetector.closedPillPixelRect(above: stem, image: pixelImage) : nil
            let closedPill = measuredPill.map(pixelImage.normalizedRect(for:))
            // Ink structure of the label, used to confirm a unit-less reading.
            let labelShape = OCREventStemDetector.labelGlyphShape(above: stem, image: pixelImage)
            let clippedPill = crossesBoundary && closedPill == nil
            let textRightEdge = closedPill?.maxX ?? layout.dataRightEdgeX
            // A measured pill next to a neighbour is read from the part that
            // holds only its own label. This covers the pill drawn in front
            // of an overlap; the one behind it is not measurable.
            let measuredRegion = measuredPill.map {
                pixelImage.normalizedRect(for: hasNeighbour ? OCREventStemDetector.labelRegion(of: $0) : $0)
            }
            let pillRegion = measuredRegion ?? OCRNormalizedRect(x: stem.pillRect.minX, y: stem.pillRect.minY,
                width: max(0, min(stem.pillRect.maxX, layout.dataRightEdgeX) - stem.pillRect.minX),
                height: stem.pillRect.height)
            // Without a measurement the split crop stays: text touching its
            // edge is not evidence, and agreeing low-confidence passes over
            // the same cut pixels are not corroboration.
            let crowded = hasNeighbour && measuredPill == nil
            // A clipped multi-digit label can look like a confident smaller
            // amount. Keep its complete stem unknown rather than parsing it.
            let pillObservations: [OCRRawTextObservation] = clippedPill ? [] : try recognizeText(
                in: cgImage,
                region: pillRegion,
                kind: .eventPill,
                minimumTextHeight: 0.02
            )
            rawObservations += pillObservations
            latestObservations = rawObservations
            let inside = pillObservations.filter {
                $0.boundingBox.maxX <= textRightEdge && (!crowded || Self.isUnclippedPillText(
                    $0.boundingBox, in: pillRegion, imageWidth: cgImage.width, imageHeight: cgImage.height))
            }
            let insideIDs = Set(pillObservations.map(\.id))
            let wholeImage: [OCRRawTextObservation] = clippedPill ? [] : OCRObservationInterpreter.eventTextEvidence(
                from: rawObservations, for: stem, among: stems
            ).filter { !insideIDs.contains($0.id) && $0.boundingBox.maxX <= textRightEdge }
            let evidence = inside + wholeImage
            var candidates = evidence
                .flatMap(\.candidates)
                .sorted { $0.confidence > $1.confidence }
            var evidenceIDs = evidence.map(\.id)
            var parsed = OCRTextParser.amount(from: candidates, expectedKind: stem.kind, labelShape: labelShape)
            var corroborated = false
            if parsed.0.value == nil && !clippedPill {
                let enhanced = try recognizeText(in: cgImage, region: pillRegion,
                    kind: .eventPill, minimumTextHeight: 0.02, enhancePill: true)
                rawObservations += enhanced
                latestObservations = rawObservations
                let usable = enhanced.filter {
                    $0.boundingBox.maxX <= textRightEdge &&
                    Self.isUnclippedPillText($0.boundingBox, in: measuredRegion ?? stem.pillRect,
                        imageWidth: cgImage.width, imageHeight: cgImage.height)
                }
                candidates += usable.flatMap(\.candidates)
                candidates.sort { $0.confidence > $1.confidence }
                evidenceIDs += usable.map(\.id)
                parsed = OCRTextParser.amount(from: candidates, expectedKind: stem.kind, labelShape: labelShape)
                if parsed.0.value == nil && !crowded {
                    // Original crop, uncropped image and enhanced crop.
                    parsed = OCRTextParser.corroboratedAmount(fromPasses: [
                        inside.flatMap(\.candidates),
                        wholeImage.flatMap(\.candidates),
                        usable.flatMap(\.candidates),
                    ], expectedKind: stem.kind)
                    corroborated = parsed.0.value != nil
                }
            }
            // The kind comes from the label row (or stem colour). A unit that
            // reads as the other kind is a contradiction, not a correction.
            let contradicted = parsed.0.value == nil
                && OCRTextParser.unitContradicts(candidates, expectedKind: stem.kind)
            therapyEvents.append(
                OCRTherapyEvent(
                    kind: contradicted ? .unknown : parsed.1,
                    date: timeline.date(atX: stem.stemRect.midX),
                    amount: parsed.0,
                    stemBoundingBox: stem.stemRect,
                    pillBoundingBox: closedPill ?? stem.pillRect,
                    isCompleteStem: true,
                    candidates: candidates,
                    confidence: min(stem.confidence, parsed.2 == 0 ? stem.confidence * 0.65 : parsed.2),
                    provenance: OCRProvenance(
                        kind: .visionText,
                        sourceObservationIDs: evidenceIDs,
                        note: contradicted
                            ? "Label row and recognized unit disagree; kind and amount stay unknown."
                            : parsed.0.value == nil
                            ? "Complete event stem found geometrically; no safe amount was recognized."
                            : corroborated
                                ? "Amount accepted from agreeing low-confidence recognition passes."
                                : nil
                    )
                )
            )
        }

        let unknownAmounts = therapyEvents.filter { $0.amount.value == nil }.count
        let unknownKinds = therapyEvents.filter { $0.kind == .unknown }.count
        let allBasalRatesKnown = !basal.steps.isEmpty
            && basal.steps.allSatisfy { $0.rateUnitsPerHour != nil }
        let basalReachesCapture = basal.steps.contains {
            $0.startDate < capturedAt && $0.endDate.timeIntervalSince(capturedAt) >= -1e-6
        }
        let criticalDataComplete = clockFailureReason == nil
            && basalCalibration != nil
            && basal.pathCoverage >= configuration.minimumBasalCoverage
            && allBasalRatesKnown
            && basalReachesCapture
            && unknownAmounts == 0
            && unknownKinds == 0

        let quality = OCRAnalysisQuality(
            layoutConfidence: layout.confidence,
            timeMaximumResidualMinutes: timeCalibration.maximumResidual,
            basalPathCoverage: basal.pathCoverage,
            glucoseSampleCount: glucose.samples.count,
            completeEventStemCount: therapyEvents.count,
            unknownEventAmountCount: unknownAmounts,
            criticalDataComplete: criticalDataComplete,
            timeAxisClockIsValid: clockFailureReason == nil
        )
        var warnings: [OCRAnalysisWarning] = []
        if let clockFailureReason {
            warnings.append(OCRAnalysisWarning(code: .timeAxisCaptureInconsistent,
                message: clockFailureReason))
        }
        if usedImportFallback {
            warnings.append(
                OCRAnalysisWarning(
                    code: .captureTimeFromImportFallback,
                    message: "No capture metadata was available; the import time is used until the user confirms it."
                )
            )
        }
        if timeCalibration.source == .singleAnchorWithFiveMinuteSpacing {
            warnings.append(
                OCRAnalysisWarning(
                    code: .timeAxisSingleAnchorFallback,
                    message: "The time scale uses one clock label plus isolated five-minute glucose spacing."
                )
            )
        }
        if basalCalibration == nil {
            warnings.append(
                OCRAnalysisWarning(
                    code: .basalAxisUncalibrated,
                    message: "Basal geometry was detected, but the rate axis is not reliable enough for numeric output."
                )
            )
        }
        if glucoseCalibration == nil {
            warnings.append(
                OCRAnalysisWarning(
                    code: .glucoseAxisUncalibrated,
                    message: "Glucose geometry is retained without numeric values because the axis is uncertain."
                )
            )
        }
        if basal.pathCoverage < configuration.minimumBasalCoverage {
            warnings.append(
                OCRAnalysisWarning(
                    code: .basalCoverageInsufficient,
                    message: "The solid basal path does not meet the required 99% coverage."
                )
            )
        }
        if !basalReachesCapture {
            warnings.append(OCRAnalysisWarning(code: .basalCaptureIntervalMissing,
                message: "Observed basal data does not reach capture; unseen delivery is not assumed."))
        }
        if unknownAmounts > 0 {
            warnings.append(
                OCRAnalysisWarning(
                    code: .eventAmountUnknown,
                    message: "At least one complete event stem has no safe amount and is excluded from calculation."
                )
            )
        }
        if unknownKinds > 0 {
            warnings.append(
                OCRAnalysisWarning(
                    code: .eventKindUnknown,
                    message: "At least one event could not be classified as insulin or carbohydrates."
                )
            )
        }
        if layout.confidence < 0.75 {
            warnings.append(
                OCRAnalysisWarning(
                    code: .lowConfidence,
                    message: "The recognized CamAPS layout has low confidence."
                )
            )
        }

        return OCRAnalysisResult(
            requestID: request.id,
            algorithmVersion: configuration.algorithmVersion,
            visionRevision: Int(VNRecognizeTextRequestRevision3),
            capturedAt: capturedAt,
            timeAxisReferenceDate: clockFailureReason == nil ? (layout.captureMarkerBounds != nil ? capturedAt : timeline.referenceDate) : nil,
            status: criticalDataComplete ? .complete : .needsReview,
            layout: layout,
            timeCalibration: timeCalibration,
            basalCalibration: basalCalibration,
            glucoseCalibration: glucoseCalibration,
            rawTextObservations: rawObservations,
            basalSteps: basal.steps,
            glucoseSamples: glucose.samples,
            therapyEvents: therapyEvents,
            quality: quality,
            warnings: warnings,
            diagnostics: OCRDiagnosticMetadata(
                imageWidth: pixelImage.width,
                imageHeight: pixelImage.height,
                removedDashedBlueComponentCount: basal.removedComponentCount,
                retainedBasalComponentCount: basal.retainedComponentCount,
                glucoseExtractionMode: glucose.mode,
                values: [
                    "pixelsPerFiveMinutes": Double(pixelImage.pixelRect(for: frame).width)
                        / max(1, visibleHours * 12),
                    "visibleHours": visibleHours,
                    "dataRightEdgeX": layout.dataRightEdgeX,
                ]
            )
        )
    }

    private func recognizeText(
        in image: CGImage,
        region: OCRNormalizedRect,
        kind: OCRRegionKind,
        minimumTextHeight: Float,
        enhancePill: Bool = false
    ) throws -> [OCRRawTextObservation] {
        let topOriginRegion = region.clampedToUnitSquare()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.customWords = ["mmol/L", "IE/h", "U/h", "Fiasp", "Lyumjev", "NovoRapid"]
        if kind == .basalAxis || kind == .glucoseAxis {
            request.customWords += (0...40).map(String.init)
        }
        request.minimumTextHeight = minimumTextHeight
        request.revision = VNRecognizeTextRequestRevision3

        let cropRect = CGRect(
            x: topOriginRegion.x * Double(image.width),
            y: topOriginRegion.y * Double(image.height),
            width: topOriginRegion.width * Double(image.width),
            height: topOriginRegion.height * Double(image.height)
        ).integral
        guard let cropped = image.cropping(to: cropRect) else {
            throw OCRAnalysisFailure.invalidImage
        }
        // Vision reports coordinates relative to the integer pixel crop.
        // Mapping via the requested fractional region introduces subpixel
        // drift, which is material on a compressed 48-hour time axis.
        let visionRegion = CGRect(
            x: cropRect.minX / Double(image.width),
            y: 1 - cropRect.maxY / Double(image.height),
            width: cropRect.width / Double(image.width),
            height: cropRect.height / Double(image.height)
        )
        let recognitionImage: CGImage
        if enhancePill {
            guard let prepared = Self.highContrastPillImage(from: cropped) else { return [] }
            recognitionImage = prepared
        } else {
            recognitionImage = cropped
        }
        let handler = VNImageRequestHandler(cgImage: recognitionImage, orientation: .up, options: [:])
        try handler.perform([request])
        let results = request.results ?? []
        return results.map { observation in
            let local = observation.boundingBox
            let fullVision = CGRect(
                x: visionRegion.minX + local.minX * visionRegion.width,
                y: visionRegion.minY + local.minY * visionRegion.height,
                width: local.width * visionRegion.width,
                height: local.height * visionRegion.height
            )
            let topOrigin = OCRNormalizedRect(
                x: fullVision.minX,
                y: 1 - fullVision.maxY,
                width: fullVision.width,
                height: fullVision.height
            ).clampedToUnitSquare()
            return OCRRawTextObservation(
                region: kind,
                boundingBox: topOrigin,
                candidates: observation.topCandidates(5).map {
                    OCRTextCandidate(text: $0.string, confidence: Double($0.confidence))
                },
                preprocessing: enhancePill ? "binary-luma-0.7-nearest-3x/v1" : nil
            )
        }
    }

    nonisolated static func makePixelImage(from image: CGImage) -> OCRPixelImage? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                      data: address,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? OCRPixelImage(width: width, height: height, rgba: rgba) : nil
    }

    private static func captureDate(
        from source: CGImageSource,
        timeZoneIdentifier: String
    ) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return candidates.lazy.compactMap(formatter.date(from:)).first
    }
}
