import Foundation

/// Screenshot region to show while a person reviews one observation.
///
/// Presentation geometry only: it never feeds extraction or calculation.
public enum ObservationCropRegion {
    /// An event observation is located by its stem; the label pill sits
    /// directly above the stem top and can overlap a neighbouring pill.
    static let eventHalfWidth = 0.07
    static let eventAboveStemTop = 0.065
    static let eventBelowStemTop = 0.035
    /// Context kept around basal and glucose geometry.
    static let horizontalMargin = 0.04
    static let verticalMargin = 0.06

    /// Returns nil when the observation has no measured geometry, as for a
    /// manually added data point.
    public static func region(
        for kind: ObservationKind, boundingBox box: NormalizedBoundingBox
    ) -> NormalizedBoundingBox? {
        guard box.isValid, box.width > 0, box.height > 0 else { return nil }
        let minX, maxX, minY, maxY: Double
        switch kind {
        case .bolus, .carbohydrate, .eventStem:
            let centre = box.x + box.width / 2
            minX = centre - eventHalfWidth
            maxX = centre + eventHalfWidth
            minY = box.y - eventAboveStemTop
            maxY = box.y + eventBelowStemTop
        case .basalRate, .glucose:
            minX = box.x - horizontalMargin
            maxX = box.x + box.width + horizontalMargin
            minY = box.y - verticalMargin
            maxY = box.y + box.height + verticalMargin
        }
        let x = max(0, minX), y = max(0, minY)
        let width = min(1, maxX) - x, height = min(1, maxY) - y
        guard width > 0, height > 0 else { return nil }
        return NormalizedBoundingBox(x: x, y: y, width: width, height: height)
    }

    /// The observation's own box expressed in the coordinates of `region`,
    /// clipped to it, for marking the reviewed signal inside the crop.
    public static func highlight(
        of box: NormalizedBoundingBox, in region: NormalizedBoundingBox
    ) -> NormalizedBoundingBox? {
        guard region.width > 0, region.height > 0 else { return nil }
        let minX = max(box.x, region.x), maxX = min(box.x + box.width, region.x + region.width)
        let minY = max(box.y, region.y), maxY = min(box.y + box.height, region.y + region.height)
        guard maxX > minX, maxY > minY else { return nil }
        return NormalizedBoundingBox(
            x: (minX - region.x) / region.width, y: (minY - region.y) / region.height,
            width: (maxX - minX) / region.width, height: (maxY - minY) / region.height)
    }
}
