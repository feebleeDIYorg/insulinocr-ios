import Foundation

/// Finds UI review intervals only. Never supplies rates or approves completeness.
enum BasalGapReview {
    static func gaps(intervals: [DateInterval], in window: DateInterval) -> [DateInterval] {
        guard window.start.timeIntervalSinceReferenceDate.isFinite,
              window.end.timeIntervalSinceReferenceDate.isFinite,
              window.duration > 0 else { return [] }
        let clipped = intervals.compactMap { interval -> DateInterval? in
            guard interval.start.timeIntervalSinceReferenceDate.isFinite,
                  interval.end.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let start = max(window.start, interval.start), end = min(window.end, interval.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var cursor = window.start
        var result: [DateInterval] = []
        for interval in clipped {
            if interval.start.timeIntervalSince(cursor) > 1e-6 {
                result.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if window.end.timeIntervalSince(cursor) > 1e-6 {
            result.append(DateInterval(start: cursor, end: window.end))
        }
        return result
    }
}
