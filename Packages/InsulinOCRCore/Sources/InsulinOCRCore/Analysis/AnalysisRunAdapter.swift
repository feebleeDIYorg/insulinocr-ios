import Foundation

public extension OCRAnalysisResult {
    /// Converts the detailed native extractor output into the stable, versioned domain run.
    /// The detailed OCR result can still be exported separately; this adapter is intentionally
    /// loss-aware and never manufactures a numeric value when calibration is unavailable.
    func makeAnalysisRun(
        caseID: UUID,
        createdAt: Date = Date(),
        diagnosticAssetSHA256: String? = nil
    ) -> AnalysisRun {
        let timeStart = date(atNormalizedX: layout.plotFrame.minX)
        let timeEnd = date(atNormalizedX: layout.dataRightEdgeX)
        let domainCalibration = AxisCalibration(
            timeStart: timeStart,
            timeEnd: timeEnd,
            plotBounds: layout.plotFrame.domainBoundingBox,
            timeResidualMinutes: timeCalibration.maximumResidual,
            basalUnitsPerNormalizedY: basalCalibration?.slope,
            glucoseUnitsPerNormalizedY: glucoseCalibration?.slope
        )

        let tokens = rawTextObservations.compactMap { observation -> OCRToken? in
            guard let best = observation.bestCandidate else { return nil }
            return OCRToken(
                id: observation.id,
                text: best.text,
                confidence: best.confidence,
                boundingBox: observation.boundingBox.domainBoundingBox,
                alternatives: observation.candidates
                    .filter { $0.text != best.text }
                    .map(\.text)
            )
        }

        var observations: [RawObservation] = []
        observations.reserveCapacity(basalSteps.count + glucoseSamples.count + therapyEvents.count)
        for step in basalSteps {
            let startX = normalizedX(for: step.startDate)
            let endX = normalizedX(for: step.endDate)
            let box = OCRNormalizedRect(
                x: min(startX, endX),
                y: max(0, step.pixelY - 0.0015),
                width: max(0.000_001, abs(endX - startX)),
                height: 0.003
            ).clampedToUnitSquare()
            observations.append(
                RawObservation(
                    id: step.id,
                    kind: .basalRate,
                    startDate: step.startDate,
                    endDate: step.endDate,
                    amount: step.rateUnitsPerHour,
                    unit: .unitsPerHour,
                    amountState: step.rateUnitsPerHour == nil ? .amountUnknown : .known,
                    boundingBox: box.domainBoundingBox,
                    confidence: ObservationConfidence(
                        overall: step.confidence,
                        geometry: step.confidence,
                        recognition: step.rateUnitsPerHour == nil ? 0 : step.confidence,
                        calibration: basalCalibration == nil ? 0 : step.confidence
                    ),
                    provenance: .pixelPath,
                    sourceIdentifier: step.provenance.note
                )
            )
        }
        for sample in glucoseSamples {
            observations.append(
                RawObservation(
                    id: sample.id,
                    kind: .glucose,
                    startDate: sample.date,
                    amount: sample.mmolPerLiter,
                    unit: .millimolesPerLiter,
                    amountState: sample.mmolPerLiter == nil ? .amountUnknown : .known,
                    boundingBox: sample.boundingBox.domainBoundingBox,
                    confidence: ObservationConfidence(
                        overall: sample.confidence,
                        geometry: sample.confidence,
                        recognition: sample.mmolPerLiter == nil ? 0 : sample.confidence,
                        calibration: glucoseCalibration == nil ? 0 : sample.confidence
                    ),
                    provenance: .pixelPath,
                    sourceIdentifier: sample.provenance.note
                )
            )
        }
        for event in therapyEvents {
            let mapped: (ObservationKind, ObservationUnit)
            switch event.kind {
            case .bolus:
                mapped = (.bolus, .insulinUnits)
            case .carbohydrates:
                mapped = (.carbohydrate, .grams)
            case .unknown:
                mapped = (.eventStem, .none)
            }
            observations.append(
                RawObservation(
                    id: event.id,
                    kind: mapped.0,
                    startDate: event.date,
                    amount: event.amount.value,
                    unit: mapped.1,
                    amountState: event.amount.value == nil ? .amountUnknown : .known,
                    boundingBox: event.stemBoundingBox.domainBoundingBox,
                    candidates: event.candidates.map {
                        ObservationCandidate(
                            text: $0.text,
                            numericValue: OCRTextParser.numericAxisValue(from: $0.text),
                            confidence: $0.confidence
                        )
                    },
                    confidence: ObservationConfidence(
                        overall: event.confidence,
                        geometry: event.isCompleteStem ? 1 : 0,
                        recognition: event.amount.value == nil ? 0 : event.confidence,
                        calibration: 1
                    ),
                    provenance: .eventGeometry,
                    sourceIdentifier: event.provenance.note
                )
            )
        }

        var blockers = Set<AnalysisBlocker>()
        if quality.timeAxisClockIsValid == false { blockers.insert(.invalidTimeAxis) }
        if timeCalibration.maximumResidual > 1 { blockers.insert(.invalidTimeAxis) }
        if basalCalibration == nil { blockers.insert(.invalidBasalAxis) }
        if quality.basalPathCoverage < 0.99 { blockers.insert(.incompleteBasalPath) }
        if therapyEvents.contains(where: { $0.kind == .bolus && $0.amount.value == nil }) {
            blockers.insert(.unknownInsulinAmount)
        }
        if therapyEvents.contains(where: { $0.kind == .carbohydrates && $0.amount.value == nil }) {
            blockers.insert(.unknownCarbohydrateAmount)
        }
        if therapyEvents.contains(where: { $0.kind == .unknown }) {
            blockers.insert(.unclassifiedEvent)
        }
        let glucoseConfidence = glucoseSamples.isEmpty
            ? 0
            : glucoseSamples.map(\.confidence).reduce(0, +) / Double(glucoseSamples.count)
        let eventConfidence = therapyEvents.isEmpty
            ? 1
            : therapyEvents.map(\.confidence).reduce(0, +) / Double(therapyEvents.count)
        let domainQuality = AnalysisQuality(
            layoutConfidence: quality.layoutConfidence,
            timeAxisConfidence: quality.timeAxisClockIsValid == false
                ? 0 : max(0, min(1, 1 - quality.timeMaximumResidualMinutes)),
            basalCoverage: quality.basalPathCoverage,
            glucoseConfidence: glucoseConfidence,
            eventConfidence: eventConfidence,
            blockers: blockers,
            warnings: warnings.map(\.message)
        )

        return AnalysisRun(
            id: id,
            caseID: caseID,
            createdAt: createdAt,
            algorithmVersion: algorithmVersion,
            visionRevision: visionRevision,
            layoutProfile: layout.profile.rawValue,
            calibration: domainCalibration,
            rawOCR: tokens,
            observations: observations.sorted(by: Self.sortObservations),
            quality: domainQuality,
            diagnosticAssetSHA256: diagnosticAssetSHA256
        )
    }

    private func date(atNormalizedX x: Double) -> Date {
        let delta = timeCalibration.value(at: x)
            - timeCalibration.value(at: layout.dataRightEdgeX)
        return (timeAxisReferenceDate ?? capturedAt).addingTimeInterval(delta * 60)
    }

    private func normalizedX(for date: Date) -> Double {
        guard abs(timeCalibration.slope) > 1e-12 else { return layout.dataRightEdgeX }
        let deltaMinutes = date.timeIntervalSince(timeAxisReferenceDate ?? capturedAt) / 60
        return min(
            layout.plotFrame.maxX,
            max(layout.plotFrame.minX, layout.dataRightEdgeX + deltaMinutes / timeCalibration.slope)
        )
    }

    private static func sortObservations(_ lhs: RawObservation, _ rhs: RawObservation) -> Bool {
        if lhs.startDate == rhs.startDate { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.startDate < rhs.startDate
    }
}

private extension OCRNormalizedRect {
    var domainBoundingBox: NormalizedBoundingBox {
        let clamped = clampedToUnitSquare()
        return NormalizedBoundingBox(
            x: clamped.x,
            y: clamped.y,
            width: clamped.width,
            height: clamped.height
        )
    }
}
