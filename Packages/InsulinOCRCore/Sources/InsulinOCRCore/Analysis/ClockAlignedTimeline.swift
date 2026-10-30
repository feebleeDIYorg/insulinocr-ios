import Foundation

extension OCRTimelineMapper {
    /// Uses metadata for the calendar day and OCR for the wall clock. The
    /// screenshot capture remains the calculation reference, not a graph tick.
    static func clockAligned(
        calibration: OCRAxisCalibration,
        plotStartX: Double,
        referenceX: Double,
        capturedAt: Date,
        timeZone: TimeZone
    ) throws -> OCRTimelineMapper {
        guard calibration.kind == .time, calibration.slope.isFinite,
              calibration.slope > 0, calibration.intercept.isFinite,
              calibration.maximumResidual.isFinite,
              (0...1).contains(calibration.maximumResidual),
              (0...1).contains(plotStartX), (0...1).contains(referenceX),
              plotStartX < referenceX,
              capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "Invalid clock calibration or capture date.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: capturedAt)
        guard let hour = components.hour, let minute = components.minute,
              let second = components.second else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "Capture date has no usable local clock.")
        }
        let localMinutes = Double(hour * 60 + minute) + Double(second) / 60
            + Double(components.nanosecond ?? 0) / 60_000_000_000
        let edgeMinutes = calibration.value(at: referenceX)
        guard edgeMinutes.isFinite else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "The observed edge has no finite clock value.")
        }
        func moduloDay(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 1_440)
            return remainder < 0 ? remainder + 1_440 : remainder
        }
        let deltaMinutes = moduloDay(localMinutes - moduloDay(edgeMinutes) + 720) - 720
        let edgeDate = capturedAt.addingTimeInterval(-deltaMinutes * 60)
        guard edgeDate.timeIntervalSince(capturedAt) <= 60 + 1e-6 else {
            throw OCRAnalysisFailure.invalidTimeAxis(
                reason: "The recognized clock places observed data more than one minute after capture.")
        }
        let elapsedSeconds = (calibration.value(at: plotStartX) - edgeMinutes) * 60
        guard elapsedSeconds.isFinite else {
            throw OCRAnalysisFailure.invalidTimeAxis(reason: "The observed clock interval is not finite.")
        }
        let startDate = edgeDate.addingTimeInterval(elapsedSeconds)
        let offset = timeZone.secondsFromGMT(for: edgeDate)
        guard timeZone.secondsFromGMT(for: startDate) == offset,
              timeZone.secondsFromGMT(for: capturedAt) == offset else {
            throw OCRAnalysisFailure.invalidTimeAxis(
                reason: "A UTC offset transition makes this linear clock layout ambiguous.")
        }
        return OCRTimelineMapper(calibration: calibration, referenceX: referenceX,
            referenceDate: edgeDate)
    }
}
