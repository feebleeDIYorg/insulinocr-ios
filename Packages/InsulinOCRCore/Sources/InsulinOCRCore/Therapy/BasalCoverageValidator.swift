import Foundation

enum BasalCoverageValidator {
    /// Lead-in a pixel path may need before its first interval is measured.
    static let observedStartTolerance: TimeInterval = 300

    /// A screenshot can be shorter than the action window. Delivery before its
    /// first observed instant cannot be identified, so completeness is then
    /// judged from the first basal interval to the reference date, provided
    /// that interval begins with the observed history. Gaps, overlaps and a
    /// missing end still fail; nothing is filled in.
    static func isComplete(_ segments: [BasalSegment], in window: DateInterval, observedStart: Date?) -> Bool {
        guard let observedStart, observedStart.timeIntervalSinceReferenceDate.isFinite,
              observedStart > window.start, observedStart < window.end,
              let first = segments.map(\.startDate).min(),
              first > window.start, first < window.end,
              first <= observedStart.addingTimeInterval(observedStartTolerance) else {
            return isComplete(segments, in: window)
        }
        return isComplete(segments, in: DateInterval(start: first, end: window.end))
    }

    static func isComplete(_ segments: [BasalSegment], in window: DateInterval) -> Bool {
        let start = window.start, referenceDate = window.end
        guard start.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              referenceDate > start else { return false }
        var intervals: [(start: Date, end: Date)] = []
        for segment in segments {
            guard segment.startDate.timeIntervalSinceReferenceDate.isFinite,
                  segment.endDate.timeIntervalSinceReferenceDate.isFinite,
                  segment.unitsPerHour.isFinite, segment.unitsPerHour >= 0,
                  segment.endDate > segment.startDate else { return false }
            let lower = max(start, segment.startDate)
            let upper = min(referenceDate, segment.endDate)
            if upper > lower { intervals.append((lower, upper)) }
        }
        intervals.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var coveredUntil = start
        // Allow only floating-point date noise, never an inferred delivery interval.
        let epsilon: TimeInterval = 1e-6
        for interval in intervals {
            let boundary = interval.start.timeIntervalSince(coveredUntil)
            guard abs(boundary) <= epsilon else { return false }
            coveredUntil = interval.end
        }
        return referenceDate.timeIntervalSince(coveredUntil) <= epsilon
    }
}
