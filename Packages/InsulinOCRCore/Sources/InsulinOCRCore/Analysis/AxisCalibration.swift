import Foundation

struct OCRTimeAnchor: Sendable, Equatable {
    let x: Double
    let minuteOfDay: Int
    let observationID: UUID?
}

struct OCRNumericAnchor: Sendable, Equatable {
    let coordinate: Double
    let value: Double
    let observationID: UUID?
}

struct OCRTimelineMapper: Sendable, Equatable {
    let calibration: OCRAxisCalibration
    let referenceX: Double
    let referenceDate: Date

    func date(atX x: Double) -> Date {
        let deltaMinutes = calibration.value(at: x) - calibration.value(at: referenceX)
        return referenceDate.addingTimeInterval(deltaMinutes * 60)
    }
}

enum OCRTextParser {
    private static let timeExpression = try! NSRegularExpression(
        pattern: #"^\s*([01]?\d|2[0-3])[:.]([0-5]\d)\s*$"#
    )
    private static let numberExpression = try! NSRegularExpression(
        pattern: #"^\s*([0-9]{1,3}(?:[.,][0-9]{1,2})?)\s*(?:mmol/?[lL]|IE/?h|U/?h)?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let bolusExpression = try! NSRegularExpression(
        pattern: #"^\s*([0-9]{1,2}(?:[.,][0-9]{1,2})?)\s*(?:IE|U)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let carbohydrateExpression = try! NSRegularExpression(
        pattern: #"^\s*([0-9]{1,3}(?:[.,][0-9])?)\s*g\s*$"#,
        options: [.caseInsensitive]
    )

    static func minuteOfDay(from text: String) -> Int? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = timeExpression.firstMatch(in: text, range: range),
              match.range == range,
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange]) else {
            return nil
        }
        return hour * 60 + minute
    }

    static func numericAxisValue(from text: String) -> Double? {
        parseNumber(in: text, expression: numberExpression)
    }

    static func amount(
        from candidates: [OCRTextCandidate],
        expectedKind: OCRTherapyEventKind
    ) -> (OCRDetectedAmount, OCRTherapyEventKind, Double) {
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        var recognized: [(Double, OCRTherapyEventKind, Double)] = []
        for candidate in sorted where candidate.confidence >= 0.35 {
            switch expectedKind {
            case .bolus:
                if let amount = parseNumber(in: candidate.text, expression: bolusExpression),
                   amount > 0, amount <= 50 {
                    recognized.append((amount, .bolus, candidate.confidence))
                }
            case .carbohydrates:
                if let amount = parseNumber(in: candidate.text, expression: carbohydrateExpression),
                   amount > 0, amount <= 300 {
                    recognized.append((amount, .carbohydrates, candidate.confidence))
                }
            case .unknown:
                if let amount = parseNumber(in: candidate.text, expression: bolusExpression),
                   amount > 0, amount <= 50 {
                    recognized.append((amount, .bolus, candidate.confidence))
                }
                if let amount = parseNumber(in: candidate.text, expression: carbohydrateExpression),
                   amount > 0, amount <= 300 {
                    recognized.append((amount, .carbohydrates, candidate.confidence))
                }
            }
        }
        guard let first = recognized.first,
              recognized.allSatisfy({ $0.0 == first.0 && $0.1 == first.1 }) else {
            return (.amountUnknown, expectedKind, 0)
        }
        return (.known(first.0), first.1, first.2)
    }

    private static func parseNumber(in text: String, expression: NSRegularExpression) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.range == range,
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[numberRange].replacingOccurrences(of: ",", with: "."))
    }
}

enum OCRObservationInterpreter {
    static func timeAnchors(
        from observations: [OCRRawTextObservation],
        horizontalRange: ClosedRange<Double>
    ) -> [OCRTimeAnchor] {
        let targeted = observations.filter {
            $0.region == .timeAxis && $0.bestCandidate.flatMap {
                OCRTextParser.minuteOfDay(from: $0.text)
            } != nil
        }
        let selected = targeted.count >= 2 ? targeted : observations
        return selected.compactMap { observation in
            guard horizontalRange.contains(observation.boundingBox.midX),
                  observation.boundingBox.minY > 0.07,
                  let candidate = observation.bestCandidate,
                  candidate.confidence >= 0.3,
                  let minute = OCRTextParser.minuteOfDay(from: candidate.text) else {
                return nil
            }
            return OCRTimeAnchor(
                x: observation.boundingBox.midX,
                minuteOfDay: minute,
                observationID: observation.id
            )
        }
        .sorted { $0.x < $1.x }
    }

    static func numericAnchors(
        from observations: [OCRRawTextObservation],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        acceptedValues: ClosedRange<Double>
    ) -> [OCRNumericAnchor] {
        observations.compactMap { observation in
            guard xRange.contains(observation.boundingBox.midX),
                  yRange.contains(observation.boundingBox.midY),
                  let candidate = observation.bestCandidate,
                  candidate.confidence >= 0.35,
                  let value = OCRTextParser.numericAxisValue(from: candidate.text),
                  acceptedValues.contains(value) else {
                return nil
            }
            return OCRNumericAnchor(
                coordinate: observation.boundingBox.midY,
                value: value,
                observationID: observation.id
            )
        }
        .sorted { $0.coordinate < $1.coordinate }
    }
}

enum TimeAxisCalibrator {
    static func calibrate(
        anchors: [OCRTimeAnchor],
        markerCentersX: [Double],
        plotRange: ClosedRange<Double>
    ) throws -> OCRAxisCalibration {
        let uniqueAnchors = deduplicated(anchors)
        if uniqueAnchors.count >= 2 {
            return try multipleAnchorCalibration(uniqueAnchors, plotRange: plotRange)
        }
        guard let anchor = uniqueAnchors.first else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "No readable time anchor was found.")
        }
        return try singleAnchorCalibration(
            anchor,
            markerCentersX: markerCentersX,
            plotRange: plotRange
        )
    }

    private static func multipleAnchorCalibration(
        _ anchors: [OCRTimeAnchor],
        plotRange: ClosedRange<Double>
    ) throws -> OCRAxisCalibration {
        let sorted = anchors.sorted { $0.x < $1.x }
        var unwrapped: [Double] = []
        for anchor in sorted {
            var value = Double(anchor.minuteOfDay)
            if let previous = unwrapped.last {
                while value <= previous {
                    value += 1_440
                }
            }
            unwrapped.append(value)
        }

        let fit = try linearRegression(
            coordinates: sorted.map(\.x),
            values: unwrapped
        )
        guard fit.slope > 0 else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "Time does not increase from left to right.")
        }
        let visibleHours = fit.slope * (plotRange.upperBound - plotRange.lowerBound) / 60
        guard (0.95...48.5).contains(visibleHours) else {
            throw OCRAnalysisFailure.unsupportedLayout(
                reason: "The calibrated window is \(visibleHours) hours; supported windows are 1–48 hours."
            )
        }
        guard fit.maximumResidual <= 1 else {
            throw OCRAnalysisFailure.invalidTimeAxis(
                reason: "Time anchor residual \(fit.maximumResidual) minutes exceeds one minute."
            )
        }

        let calibrationAnchors = zip(sorted, unwrapped).map { anchor, value in
            OCRCalibrationAnchor(
                coordinate: anchor.x,
                value: value,
                sourceObservationID: anchor.observationID
            )
        }
        return OCRAxisCalibration(
            kind: .time,
            source: .multipleOCRAnchors,
            slope: fit.slope,
            intercept: fit.intercept,
            maximumResidual: fit.maximumResidual,
            anchors: calibrationAnchors
        )
    }

    private static func singleAnchorCalibration(
        _ anchor: OCRTimeAnchor,
        markerCentersX: [Double],
        plotRange: ClosedRange<Double>
    ) throws -> OCRAxisCalibration {
        let positions = markerCentersX
            .filter(plotRange.contains)
            .sorted()
        let positiveDeltas = zip(positions, positions.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0.000_01 }
            .sorted()
        guard positiveDeltas.count >= 3 else {
            throw OCRAnalysisFailure.invalidTimeAxis(
                reason: "A single time anchor needs at least four isolated five-minute glucose markers."
            )
        }

        // Missing markers create multiples of the fundamental spacing. The lower half is
        // deliberately used instead of the global median to stay anchored to five minutes.
        let lowerCount = max(1, (positiveDeltas.count + 1) / 2)
        let fiveMinuteSpacing = median(Array(positiveDeltas.prefix(lowerCount)))
        let slope = 5 / fiveMinuteSpacing
        let visibleHours = slope * (plotRange.upperBound - plotRange.lowerBound) / 60
        guard (0.95...48.5).contains(visibleHours) else {
            throw OCRAnalysisFailure.unsupportedLayout(
                reason: "The five-minute fallback implies \(visibleHours) visible hours."
            )
        }
        let intercept = Double(anchor.minuteOfDay) - slope * anchor.x
        return OCRAxisCalibration(
            kind: .time,
            source: .singleAnchorWithFiveMinuteSpacing,
            slope: slope,
            intercept: intercept,
            maximumResidual: 0,
            anchors: [
                OCRCalibrationAnchor(
                    coordinate: anchor.x,
                    value: Double(anchor.minuteOfDay),
                    sourceObservationID: anchor.observationID
                ),
            ]
        )
    }

    private static func deduplicated(_ anchors: [OCRTimeAnchor]) -> [OCRTimeAnchor] {
        anchors.sorted { $0.x < $1.x }.reduce(into: []) { result, anchor in
            if let last = result.last,
               last.minuteOfDay == anchor.minuteOfDay,
               abs(last.x - anchor.x) < 0.02 {
                result[result.count - 1] = OCRTimeAnchor(
                    x: (last.x + anchor.x) / 2,
                    minuteOfDay: last.minuteOfDay,
                    observationID: last.observationID
                )
                return
            }
            guard result.last.map({ abs($0.x - anchor.x) < 0.002 }) != true else { return }
            result.append(anchor)
        }
    }
}

enum NumericAxisCalibrator {
    static func calibrate(
        kind: OCRAxisKind,
        anchors: [OCRNumericAnchor],
        allowedResidual: Double
    ) -> OCRAxisCalibration? {
        guard kind != .time else { return nil }
        let unique = anchors.reduce(into: [OCRNumericAnchor]()) { result, anchor in
            guard result.last.map({ abs($0.coordinate - anchor.coordinate) < 0.002 }) != true else { return }
            result.append(anchor)
        }
        guard unique.count >= 2,
              let fit = try? linearRegression(
                  coordinates: unique.map(\.coordinate),
                  values: unique.map(\.value)
              ),
              fit.slope < 0,
              fit.maximumResidual <= allowedResidual else {
            return nil
        }
        return OCRAxisCalibration(
            kind: kind,
            source: .numericAxisAnchors,
            slope: fit.slope,
            intercept: fit.intercept,
            maximumResidual: fit.maximumResidual,
            anchors: unique.map {
                OCRCalibrationAnchor(
                    coordinate: $0.coordinate,
                    value: $0.value,
                    sourceObservationID: $0.observationID
                )
            }
        )
    }
}

private struct LinearFit {
    let slope: Double
    let intercept: Double
    let maximumResidual: Double
}

private func linearRegression(coordinates: [Double], values: [Double]) throws -> LinearFit {
    guard coordinates.count == values.count, coordinates.count >= 2 else {
        throw OCRAnalysisFailure.invalidTimeAxis(reason: "At least two calibration points are required.")
    }
    let count = Double(coordinates.count)
    let meanX = coordinates.reduce(0, +) / count
    let meanY = values.reduce(0, +) / count
    let denominator = coordinates.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
    guard denominator > 1e-12 else {
        throw OCRAnalysisFailure.invalidTimeAxis(reason: "Calibration points have no horizontal spread.")
    }
    let numerator = zip(coordinates, values).reduce(0.0) {
        $0 + ($1.0 - meanX) * ($1.1 - meanY)
    }
    let slope = numerator / denominator
    let intercept = meanY - slope * meanX
    let residual = zip(coordinates, values)
        .map { abs(($0 * slope + intercept) - $1) }
        .max() ?? .infinity
    return LinearFit(slope: slope, intercept: intercept, maximumResidual: residual)
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
