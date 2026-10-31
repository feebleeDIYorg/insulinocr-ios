import Foundation

/// ISO 8601 strings with fractional seconds; old whole-second payloads stay readable.
enum PreciseISO8601DateCoding {
    static func string(from date: Date) -> String? {
        let interval = date.timeIntervalSinceReferenceDate
        guard interval.isFinite else { return nil }
        var whole = floor(interval)
        var nanos = Int(((interval - whole) * 1_000_000_000).rounded())
        if nanos == 1_000_000_000 { whole += 1; nanos = 0 }
        let base = Date(timeIntervalSinceReferenceDate: whole).ISO8601Format()
        guard base.hasSuffix("Z") else { return nil }
        guard nanos != 0 else { return base }
        let digits = String(nanos)
        return String(base.dropLast()) + "." + String(repeating: "0", count: 9 - digits.count) + digits + "Z"
    }

    static func encode(_ date: Date, to encoder: any Encoder) throws {
        guard let value = string(from: date) else {
            throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath,
                debugDescription: "Timestamp must be a finite ISO 8601 date."))
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func decode(from decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        var base = value
        var fraction = 0.0
        if let dot = value.firstIndex(of: ".") {
            let start = value.index(after: dot)
            guard let suffix = value[start...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Missing timestamp offset.")
            }
            let digits = value[start..<suffix]
            guard (1...9).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Double("0." + digits) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid fractional timestamp.")
            }
            fraction = parsed
            base = String(value[..<dot]) + String(value[suffix...])
        }
        do { return try Date.ISO8601FormatStyle().parse(base).addingTimeInterval(fraction) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp.")
        }
    }
}
