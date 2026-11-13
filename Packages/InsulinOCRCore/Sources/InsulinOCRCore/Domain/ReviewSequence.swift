import Foundation

/// Fixed order in which unconfirmed data points are stepped through during
/// one review. An item stays in the sequence after its value was entered, so
/// a typing error can be reached again with "back".
///
/// Presentation state only: it never feeds extraction or calculation.
public struct ReviewSequence: Equatable, Sendable {
    public private(set) var ids: [UUID]

    public init(ids: [UUID] = []) {
        var seen = Set<UUID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }

    public mutating func append(_ id: UUID) {
        if !ids.contains(id) { ids.append(id) }
    }

    /// Zero-based position of `id`, or nil when it is not under review.
    public func position(of id: UUID?) -> Int? {
        id.flatMap(ids.firstIndex(of:))
    }

    /// The item `step` places from `current`. From outside the sequence a
    /// forward step enters at the first item `isOpen` accepts, or at the
    /// start when none is open. Nil at either end.
    public func target(from current: UUID?, step: Int, isOpen: (UUID) -> Bool) -> UUID? {
        guard !ids.isEmpty, step != 0 else { return nil }
        guard let index = position(of: current) else {
            return step > 0 ? (ids.first(where: isOpen) ?? ids[0]) : nil
        }
        let next = index + step
        return ids.indices.contains(next) ? ids[next] : nil
    }

    public func openCount(isOpen: (UUID) -> Bool) -> Int {
        ids.filter(isOpen).count
    }
}
