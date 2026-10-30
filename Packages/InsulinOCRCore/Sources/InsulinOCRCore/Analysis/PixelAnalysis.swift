import Foundation

struct OCRPixelColor: Sendable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var isTherapyBlue: Bool {
        blue >= 105 && Int(blue) >= Int(red) + 28 && Int(blue) >= Int(green) + 8
            && Int(green) >= Int(red) + 20
    }

    var isCarbohydrateOrange: Bool {
        red >= 145 && green >= 55 && green <= 215 && blue <= 135 && Int(red) >= Int(green) + 20
    }

    var isDarkInk: Bool {
        red <= 90 && green <= 90 && blue <= 90 && alpha >= 80
    }
}

struct OCRPixelImage: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    subscript(x: Int, y: Int) -> OCRPixelColor {
        let clampedX = min(width - 1, max(0, x))
        let clampedY = min(height - 1, max(0, y))
        let index = (clampedY * width + clampedX) * 4
        return OCRPixelColor(
            red: rgba[index],
            green: rgba[index + 1],
            blue: rgba[index + 2],
            alpha: rgba[index + 3]
        )
    }

    func pixelRect(for rect: OCRNormalizedRect) -> OCRPixelRect {
        let clamped = rect.clampedToUnitSquare()
        let x = min(width - 1, max(0, Int((clamped.x * Double(width)).rounded(.down))))
        let y = min(height - 1, max(0, Int((clamped.y * Double(height)).rounded(.down))))
        let maxX = min(width, max(x + 1, Int((clamped.maxX * Double(width)).rounded(.up))))
        let maxY = min(height, max(y + 1, Int((clamped.maxY * Double(height)).rounded(.up))))
        return OCRPixelRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    func normalizedRect(for rect: OCRPixelRect) -> OCRNormalizedRect {
        OCRNormalizedRect(
            x: Double(rect.x) / Double(width),
            y: Double(rect.y) / Double(height),
            width: Double(rect.width) / Double(width),
            height: Double(rect.height) / Double(height)
        )
    }
}

struct OCRPixelRect: Sendable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
}

struct OCRBinaryMask: Sendable, Equatable {
    let width: Int
    let height: Int
    var values: [UInt8]

    init(width: Int, height: Int, values: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.values = values ?? [UInt8](repeating: 0, count: width * height)
        precondition(self.values.count == width * height)
    }

    subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return values[y * width + x] != 0
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            values[y * width + x] = newValue ? 1 : 0
        }
    }

    mutating func clear(rect: OCRPixelRect) {
        let startX = max(0, rect.x)
        let endX = min(width, rect.maxX)
        let startY = max(0, rect.y)
        let endY = min(height, rect.maxY)
        guard startX < endX, startY < endY else { return }
        for y in startY..<endY {
            for x in startX..<endX {
                values[y * width + x] = 0
            }
        }
    }
}

struct OCRPixelComponent: Sendable, Equatable {
    let pixelIndices: [Int]
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var pixelCount: Int { pixelIndices.count }
    var centerX: Double { (Double(minX) + Double(maxX)) / 2 }
    var centerY: Double { (Double(minY) + Double(maxY)) / 2 }
}

enum OCRConnectedComponents {
    static func find(in mask: OCRBinaryMask) -> [OCRPixelComponent] {
        var visited = [UInt8](repeating: 0, count: mask.values.count)
        var result: [OCRPixelComponent] = []
        result.reserveCapacity(128)

        for startIndex in mask.values.indices where mask.values[startIndex] != 0 && visited[startIndex] == 0 {
            var queue = [startIndex]
            visited[startIndex] = 1
            var cursor = 0
            var indices: [Int] = []
            var minX = mask.width
            var maxX = 0
            var minY = mask.height
            var maxY = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                indices.append(index)
                let x = index % mask.width
                let y = index / mask.width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                for deltaY in -1...1 {
                    for deltaX in -1...1 where deltaX != 0 || deltaY != 0 {
                        let nextX = x + deltaX
                        let nextY = y + deltaY
                        guard nextX >= 0, nextX < mask.width,
                              nextY >= 0, nextY < mask.height else { continue }
                        let nextIndex = nextY * mask.width + nextX
                        guard mask.values[nextIndex] != 0, visited[nextIndex] == 0 else { continue }
                        visited[nextIndex] = 1
                        queue.append(nextIndex)
                    }
                }
            }
            result.append(
                OCRPixelComponent(
                    pixelIndices: indices,
                    minX: minX,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY
                )
            )
        }
        return result
    }
}

struct OCRDetectedEventStem: Sendable, Equatable {
    let kind: OCRTherapyEventKind
    let stemRect: OCRNormalizedRect
    let pillRect: OCRNormalizedRect
    let isComplete: Bool
    let confidence: Double
}

enum OCRLayoutDetector {
    static func alignNumericAnchors(
        _ anchors: [OCRNumericAnchor], image: OCRPixelImage,
        frame: OCRNormalizedRect, kind: OCRAxisKind
    ) -> [OCRNumericAnchor] {
        let edge = kind == .basalRate ? frame.minX : frame.maxX
        let near = kind == .basalRate ? edge - 0.009 : edge + 0.002
        let far = kind == .basalRate ? edge - 0.002 : edge + 0.009
        let left = max(0, Int(near * Double(image.width)))
        let right = min(image.width, Int(far * Double(image.width)))
        guard right > left else { return anchors }
        return anchors.map { anchor in
            let center = Int(anchor.coordinate * Double(image.height))
            let radius = max(3, image.height / 100)
            var scores: [(y: Int, count: Int)] = []
            for y in max(0, center - radius)...min(image.height - 1, center + radius) {
                var count = 0
                for x in left..<right {
                    let c = image[x, y]
                    if (100...195).contains(Int(c.red)),
                       abs(Int(c.red) - Int(c.green)) <= 8,
                       abs(Int(c.red) - Int(c.blue)) <= 8 { count += 1 }
                }
                scores.append((y, count))
            }
            let best = scores.map(\.count).max() ?? 0
            guard best >= max(3, (right - left) / 3) else { return anchor }
            let rows = scores.filter { Double($0.count) >= Double(best) * 0.9 }.map { Double($0.y) }
            let coordinate = rows.reduce(0, +) / Double(rows.count) / Double(image.height)
            return OCRNumericAnchor(coordinate: coordinate, value: anchor.value, observationID: anchor.observationID)
        }
    }

    static func alignTimeAnchors(
        _ anchors: [OCRTimeAnchor], image: OCRPixelImage, frame: OCRNormalizedRect
    ) -> [OCRTimeAnchor] {
        let bounds = image.pixelRect(for: frame)
        return anchors.map { anchor in
            let center = Int(anchor.x * Double(image.width))
            let radius = max(2, image.width / 120)
            var columnScores: [(x: Int, count: Int, contrast: Int)] = []
            for x in max(bounds.x, center - radius)...min(bounds.maxX - 1, center + radius) {
                var count = 0
                var contrast = 0
                for y in stride(from: bounds.y + 4, to: bounds.maxY - 4, by: 2) {
                    let c = image[x, y]
                    if (120...225).contains(Int(c.red)),
                       abs(Int(c.red) - Int(c.green)) <= 8,
                       Int(c.blue) <= Int(c.red) + 8,
                       Int(c.red) - Int(c.blue) <= 60 {
                        count += 1
                        contrast += 255 - Int(c.red)
                    }
                }
                columnScores.append((x, count, contrast))
            }
            let supported = columnScores.filter { $0.count > bounds.height / 5 }
            guard let bestContrast = supported.map(\.contrast).max() else { return anchor }
            // Anti-aliasing and traces crossing a rule slightly change each
            // column's score. Centre the strong raster band, not one pixel.
            // A grey future panel supports every column. Prefer the darker
            // raster, and retain OCR geometry when only a broad band exists.
            let bestColumns = supported.filter {
                Double($0.contrast) >= Double(bestContrast) * 0.9
            }.map(\.x)
            guard let first = bestColumns.first, let last = bestColumns.last,
                  last - first + 1 <= max(6, image.width / 250) else { return anchor }
            let bestX = bestColumns.map(Double.init).reduce(0, +) / Double(bestColumns.count)
            return OCRTimeAnchor(x: bestX / Double(image.width), minuteOfDay: anchor.minuteOfDay, observationID: anchor.observationID)
        }
    }

    static func detect(
        image: OCRPixelImage,
        observations: [OCRRawTextObservation]
    ) throws -> (plotFrame: OCRNormalizedRect, dataRightEdgeX: Double, confidence: Double) {
        guard image.width > image.height else {
            throw OCRAnalysisFailure.unsupportedLayout(reason: "The screenshot is not landscape.")
        }
        let aspect = Double(image.width) / Double(image.height)
        guard image.width >= 800, image.height >= 350, (1.45...2.75).contains(aspect) else {
            throw OCRAnalysisFailure.unsupportedLayout(
                reason: "Unexpected image dimensions \(image.width)×\(image.height)."
            )
        }

        let frame = try detectPlotFrame(image: image)
        let anchors = OCRObservationInterpreter.timeAnchors(
            from: observations,
            horizontalRange: frame.minX...frame.maxX
        )
        guard !anchors.isEmpty else {
            throw OCRAnalysisFailure.unsupportedLayout(reason: "No CamAPS-style time label was found.")
        }

        let pixelRect = image.pixelRect(for: frame)
        var blueCount = 0
        var darkCount = 0
        var rightMostX = pixelRect.x
        for y in stride(from: pixelRect.y, to: pixelRect.maxY, by: 2) {
            for x in stride(from: pixelRect.x, to: pixelRect.maxX, by: 2) {
                let color = image[x, y]
                if color.isTherapyBlue {
                    blueCount += 1
                    rightMostX = max(rightMostX, x)
                }
                if color.isDarkInk {
                    darkCount += 1
                    rightMostX = max(rightMostX, x)
                }
            }
        }
        guard blueCount >= 20, darkCount >= 20 else {
            throw OCRAnalysisFailure.unsupportedLayout(
                reason: "Required blue basal and dark glucose/event geometry is absent."
            )
        }

        let normalizedRight = Double(rightMostX) / Double(image.width)
        let minimumUsableRight = frame.minX + frame.width * 0.55
        let observedRight = futurePanelBoundary(image: image, frame: frame) ?? normalizedRight
        let dataRightEdge = min(frame.maxX, max(minimumUsableRight, observedRight))
        let confidence = min(1, 0.55 + min(0.2, Double(anchors.count) * 0.04)
            + min(0.15, Double(blueCount) / 2_000)
            + min(0.1, Double(darkCount) / 4_000))
        return (frame, dataRightEdge, confidence)
    }

    static func futurePanelBoundary(image: OCRPixelImage, frame: OCRNormalizedRect) -> Double? {
        let bounds = image.pixelRect(for: frame)
        let minimumWidth = max(8, bounds.width / 40)
        let edgeTolerance = max(12, bounds.width / 30)
        var panelRight: Int?
        var panelLeft: Int?
        var gap = 0
        for x in stride(from: bounds.maxX - 1, through: bounds.x + bounds.width / 2, by: -1) {
            var grey = 0
            var total = 0
            for y in stride(from: bounds.y + 4, to: bounds.maxY - 4, by: 4) {
                total += 1
                let c = image[x, y]
                let r = Int(c.red), g = Int(c.green), b = Int(c.blue)
                let neutralOrYellow = abs(r - g) <= 5 && b <= r + 5 && r - b <= 60
                let redOverlay = abs(g - b) <= 5 && g <= r && r - g <= 60
                if (190...225).contains(r), neutralOrYellow || redOverlay { grey += 1 }
            }
            let isPanel = total > 0 && Double(grey) / Double(total) >= 0.8
            if isPanel {
                panelRight = panelRight ?? x
                panelLeft = x
                gap = 0
            } else if let right = panelRight, let left = panelLeft {
                // Thin vertical gridlines also cross the future panel.
                gap += 1
                if gap <= max(4, image.width / 300) { continue }
                guard right - left + 1 >= minimumWidth else { return nil }
                return Double(left) / Double(image.width)
            } else if bounds.maxX - x > edgeTolerance {
                return nil
            }
        }
        return nil
    }

    static func detectPlotFrame(image: OCRPixelImage) throws -> OCRNormalizedRect {
        // Long neutral-grey horizontal rules identify the actual chart bounds,
        // independent of side margins and the event-label area above the plot.
        var rules: [(y: Int, start: Int, end: Int)] = []
        for y in Int(Double(image.height) * 0.12)..<Int(Double(image.height) * 0.94) {
            var start: Int?
            var best: (start: Int, end: Int)?
            for x in 0...image.width {
                let grey: Bool
                if x < image.width {
                    let c = image[x, y]
                    grey = (100...195).contains(Int(c.red))
                        && abs(Int(c.red) - Int(c.green)) <= 8
                        && abs(Int(c.red) - Int(c.blue)) <= 8
                } else { grey = false }
                if grey {
                    if start == nil { start = x }
                } else if let s = start {
                    if x - s > (best.map { $0.end - $0.start } ?? 0) { best = (s, x) }
                    start = nil
                }
            }
            if let best, best.end - best.start >= image.width / 2 {
                rules.append((y, best.start, best.end))
            }
        }
        guard let top = rules.first, let bottom = rules.last else {
            throw OCRAnalysisFailure.unsupportedLayout(reason: "No reliable chart frame was detected.")
        }
        var left = min(top.start, bottom.start)
        let right = max(top.end, bottom.end)
        var axisTop = top.y
        var axisBottom = bottom.y
        var bestAxisCount = 0
        let axisSearchEnd = min(image.width, left + max(9, image.width / 50))
        for x in max(0, left - 3)..<axisSearchEnd {
            var ys: [Int] = []
            for y in Int(Double(image.height) * 0.12)..<Int(Double(image.height) * 0.94) {
                let c = image[x, y]
                if (100...195).contains(Int(c.red)),
                   abs(Int(c.red) - Int(c.green)) <= 8,
                   abs(Int(c.red) - Int(c.blue)) <= 8 { ys.append(y) }
            }
            if ys.count > bestAxisCount, ys.count > image.height / 3,
               let first = ys.first, let last = ys.last {
                bestAxisCount = ys.count
                left = x
                axisTop = min(top.y, first)
                axisBottom = max(bottom.y, last)
            }
        }
        guard axisBottom - axisTop > image.height / 3 else {
            throw OCRAnalysisFailure.unsupportedLayout(reason: "Chart bounds have insufficient vertical extent.")
        }
        return OCRNormalizedRect(
            x: Double(left) / Double(image.width),
            y: Double(axisTop) / Double(image.height),
            width: Double(right - left) / Double(image.width),
            height: Double(axisBottom - axisTop) / Double(image.height)
        )
    }
}

enum OCREventStemDetector {
    static func detect(image: OCRPixelImage, plotFrame: OCRNormalizedRect) -> [OCRDetectedEventStem] {
        let eventTop = max(0, plotFrame.minY - 0.16)
        let eventBottom = min(1, plotFrame.minY + 0.07)
        let crop = image.pixelRect(for: OCRNormalizedRect(
            x: plotFrame.minX,
            y: eventTop,
            width: plotFrame.width,
            height: eventBottom - eventTop
        ))
        let scanHeight = crop.height
        let minimumRun = max(10, Int(Double(image.height) * 0.04))
        var qualifyingColumns: [(x: Int, minY: Int, maxY: Int)] = []

        for localX in 0..<crop.width {
            var bestStart = 0
            var bestEnd = -1
            var currentStart: Int?
            for localY in 0..<scanHeight {
                let color = image[crop.x + localX, crop.y + localY]
                let eventInk = color.isDarkInk || color.isTherapyBlue || color.isCarbohydrateOrange
                if eventInk, currentStart == nil {
                    currentStart = localY
                } else if !eventInk, let start = currentStart {
                    if localY - start > bestEnd - bestStart + 1 {
                        bestStart = start
                        bestEnd = localY - 1
                    }
                    currentStart = nil
                }
            }
            if let start = currentStart, scanHeight - start > bestEnd - bestStart + 1 {
                bestStart = start
                bestEnd = scanHeight - 1
            }
            if bestEnd - bestStart + 1 >= minimumRun {
                qualifyingColumns.append((localX, bestStart, bestEnd))
            }
        }

        var groups: [[(x: Int, minY: Int, maxY: Int)]] = []
        for column in qualifyingColumns {
            if let lastX = groups.last?.last?.x, column.x <= lastX + 1 {
                groups[groups.count - 1].append(column)
            } else {
                groups.append([column])
            }
        }

        let stems = groups.compactMap { group -> OCRDetectedEventStem? in
            guard let first = group.first, let last = group.last,
                  group.count <= max(14, crop.width / 100) else { return nil }
            let minY = group.map(\.minY).min() ?? 0
            let maxY = group.map(\.maxY).max() ?? 0
            let stemPixelRect = OCRPixelRect(
                x: crop.x + first.x,
                y: crop.y + minY,
                width: last.x - first.x + 1,
                height: maxY - minY + 1
            )
            // Event stems originate in a pill above the chart. Coloured
            // status strips and graph features beginning inside it are not
            // therapy events, even when they form a long vertical run.
            guard Double(stemPixelRect.y) / Double(image.height) < plotFrame.minY else {
                return nil
            }
            let centerX = stemPixelRect.x + stemPixelRect.width / 2
            var blue = 0
            var orange = 0
            let colorSampleRadius = max(4, crop.width / 180)
            for y in max(crop.y, stemPixelRect.y - colorSampleRadius)..<min(crop.maxY, stemPixelRect.maxY + colorSampleRadius) {
                for x in max(crop.x, centerX - colorSampleRadius)..<min(crop.maxX, centerX + colorSampleRadius + 1) {
                    let color = image[x, y]
                    blue += color.isTherapyBlue ? 1 : 0
                    orange += color.isCarbohydrateOrange ? 1 : 0
                }
            }
            let kind: OCRTherapyEventKind
            if blue > max(3, orange * 2) {
                kind = .bolus
            } else if orange > max(3, blue * 2) {
                kind = .carbohydrates
            } else {
                kind = .unknown
            }
            let normalizedStem = image.normalizedRect(for: stemPixelRect)
            let pillWidth = max(0.035, min(0.075, Double(crop.width) / Double(image.width) * 0.07))
            let pillHeight = 0.045
            let pill = OCRNormalizedRect(
                x: normalizedStem.midX - pillWidth / 2,
                y: max(0, normalizedStem.minY - pillHeight),
                width: pillWidth,
                height: pillHeight
            ).clampedToUnitSquare()
            let complete = first.x > 2 && last.x < crop.width - 3 && stemPixelRect.height >= minimumRun
            let lengthConfidence = min(1, Double(stemPixelRect.height) / Double(minimumRun * 2))
            return OCRDetectedEventStem(
                kind: kind,
                stemRect: normalizedStem,
                pillRect: pill,
                isComplete: complete,
                confidence: 0.55 + lengthConfidence * 0.35 + (kind == .unknown ? 0 : 0.1)
            )
        }
        return isolatePillRegions(recoverStackedBolusStems(stems, image: image, frame: plotFrame))
    }

    static func recoverStackedBolusStems(
        _ stems: [OCRDetectedEventStem], image: OCRPixelImage, frame: OCRNormalizedRect
    ) -> [OCRDetectedEventStem] {
        var result = stems
        for lower in stems where lower.isComplete && lower.stemRect.minY > frame.minY - 0.04 {
            let x = Int(lower.stemRect.midX * Double(image.width))
            let lowerY = Int(lower.stemRect.minY * Double(image.height))
            let firstY = max(0, lowerY - Int(Double(image.height) * 0.075))
            let lastY = max(firstY, lowerY - Int(Double(image.height) * 0.04))
            var best: (start: Int, end: Int)?
            var start: Int?
            for y in firstY...lastY {
                if y < lastY && image[x, y].isDarkInk {
                    start = start ?? y
                } else if let beginning = start {
                    if y - beginning > (best.map { $0.end - $0.start } ?? 0) { best = (beginning, y) }
                    start = nil
                }
            }
            guard let stub = best, stub.end - stub.start >= max(4, image.height / 125) else { continue }
            let top = Double(stub.start) / Double(image.height)
            guard !stems.contains(where: {
                abs($0.stemRect.midX - lower.stemRect.midX) < 3 / Double(image.width)
                    && abs($0.stemRect.minY - top) < 4 / Double(image.height)
            }) else { continue }
            let pill = OCRNormalizedRect(x: lower.pillRect.x, y: max(0, top - 0.045),
                width: lower.pillRect.width, height: 0.045).clampedToUnitSquare()
            let bounds = image.pixelRect(for: pill)
            var blue = 0
            for y in bounds.y..<bounds.maxY {
                for px in bounds.x..<bounds.maxX where image[px, y].isTherapyBlue { blue += 1 }
            }
            guard blue >= 10 else { continue }
            result.append(OCRDetectedEventStem(kind: .bolus,
                stemRect: .init(x: lower.stemRect.x, y: top, width: lower.stemRect.width,
                    height: lower.stemRect.maxY - top),
                pillRect: pill, isComplete: true, confidence: min(lower.confidence, 0.85)))
        }
        return result.sorted { ($0.stemRect.midX, $0.stemRect.minY) < ($1.stemRect.midX, $1.stemRect.minY) }
    }

    static func isolatePillRegions(_ stems: [OCRDetectedEventStem]) -> [OCRDetectedEventStem] {
        stems.map { stem in
            var left = stem.pillRect.minX
            var right = stem.pillRect.maxX
            for other in stems where other.stemRect != stem.stemRect {
                // Only neighbours on the same label row compete for pixels.
                guard abs(other.stemRect.minY - stem.stemRect.minY) < 0.015 else { continue }
                let boundary = (other.stemRect.midX + stem.stemRect.midX) / 2
                if other.stemRect.midX < stem.stemRect.midX {
                    left = max(left, boundary)
                } else {
                    right = min(right, boundary)
                }
            }
            guard left != stem.pillRect.minX || right != stem.pillRect.maxX else { return stem }
            return OCRDetectedEventStem(kind: stem.kind, stemRect: stem.stemRect,
                pillRect: OCRNormalizedRect(x: left, y: stem.pillRect.y,
                    width: max(0, right - left), height: stem.pillRect.height),
                isComplete: stem.isComplete, confidence: stem.confidence)
        }
    }
}

struct OCRBasalExtraction: Sendable {
    let steps: [OCRBasalStep]
    let pathCoverage: Double
    let removedComponentCount: Int
    let retainedComponentCount: Int
}

enum OCRBasalPathExtractor {
    static func extract(
        image: OCRPixelImage,
        plotFrame: OCRNormalizedRect,
        excludedRects: [OCRNormalizedRect],
        timeline: OCRTimelineMapper,
        rateCalibration: OCRAxisCalibration?
    ) -> OCRBasalExtraction {
        let crop = image.pixelRect(for: plotFrame)
        var mask = OCRBinaryMask(width: crop.width, height: crop.height)
        for localY in 0..<crop.height {
            for localX in 0..<crop.width {
                mask[localX, localY] = image[crop.x + localX, crop.y + localY].isTherapyBlue
            }
        }
        for rect in excludedRects {
            let absolute = image.pixelRect(for: rect)
            mask.clear(rect: OCRPixelRect(
                x: absolute.x - crop.x - 2,
                y: absolute.y - crop.y - 2,
                width: absolute.width + 4,
                height: absolute.height + 4
            ))
        }

        let components = OCRConnectedComponents.find(in: mask)
        let retained = components.filter {
            $0.pixelCount >= 100 || ($0.height >= 9 && $0.width >= 10)
        }
        let retainedIndices = Set(retained.flatMap(\.pixelIndices))
        var pathY = [Double?](repeating: nil, count: crop.width)
        var verticalStroke = [Bool](repeating: false, count: crop.width)
        for x in 0..<crop.width {
            var ys: [Int] = []
            for y in 0..<crop.height where retainedIndices.contains(y * crop.width + x) {
                ys.append(y)
            }
            if !ys.isEmpty {
                // CamAPS paints the step stroke above its rate ordinate: the
                // lower contour, including a zero plateau at the axis, carries
                // the value. Its centre overstates delivery by half a stroke.
                pathY[x] = Double(ys[ys.count - 1])
                var longest = 0, current = 0, previous = -2
                for y in ys {
                    current = y == previous + 1 ? current + 1 : 1
                    longest = max(longest, current)
                    previous = y
                }
                verticalStroke[x] = longest > max(6, image.height / 100)
            }
        }
        let detectedColumns = pathY.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        let coverage = Double(detectedColumns) / Double(max(1, crop.width))
        reconstructShortGaps(in: &pathY, maximumGap: max(2, crop.width / 500))
        let pixelsPerFiveMinutes = 5 * Double(image.width) / timeline.calibration.slope
        if pixelsPerFiveMinutes.isFinite && pixelsPerFiveMinutes >= 6 {
            resolveVerticalTransitions(in: &pathY, verticalStroke: verticalStroke,
                maximumWidth: max(12, image.width / 100))
        }

        var runs: [(start: Int, end: Int, y: Double)] = []
        var runStart: Int?
        var runValues: [Double] = []
        for x in 0...pathY.count {
            let candidate = x < pathY.count ? pathY[x] : nil
            if let candidate {
                if let last = runValues.last, abs(candidate - last) > 2.5 {
                    if let start = runStart {
                        runs.append((start, x, medianDouble(runValues)))
                    }
                    runStart = x
                    runValues = [candidate]
                } else {
                    runStart = runStart ?? x
                    runValues.append(candidate)
                }
            } else if let start = runStart {
                runs.append((start, x, medianDouble(runValues)))
                runStart = nil
                runValues = []
            }
        }

        let steps = runs.compactMap { run -> OCRBasalStep? in
            guard run.end > run.start else { return nil }
            let startX = Double(crop.x + run.start) / Double(image.width)
            let endX = Double(crop.x + run.end) / Double(image.width)
            let normalizedY = Double(crop.y) / Double(image.height) + run.y / Double(image.height)
            let startDate = timeline.date(atX: startX)
            let endDate = timeline.date(atX: endX)
            guard endDate > startDate else { return nil }
            let rawRate = rateCalibration?.value(at: normalizedY)
            // A fitted zero ordinate can round a few ulps below zero. Do not
            // turn numerical noise into an unknown basal amount, or accept a
            // materially negative calibration result.
            let rate = rawRate.flatMap { (-1e-9...20).contains($0) ? max(0, $0) : nil }
            return OCRBasalStep(
                startDate: startDate,
                endDate: endDate,
                rateUnitsPerHour: rate,
                pixelY: normalizedY,
                confidence: min(1, 0.55 + coverage * 0.45),
                provenance: OCRProvenance(
                    kind: .calibratedPixelGeometry,
                    note: rate == nil ? "Basal geometry found, but rate-axis calibration is unavailable." : nil
                )
            )
        }

        return OCRBasalExtraction(
            steps: steps,
            pathCoverage: coverage,
            removedComponentCount: components.count - retained.count,
            retainedComponentCount: retained.count
        )
    }

    static func reconstructShortGaps(in path: inout [Double?], maximumGap: Int) {
        guard maximumGap > 0, path.count >= 3 else { return }
        var index = 1
        while index < path.count - 1 {
            guard path[index] == nil else {
                index += 1
                continue
            }
            let start = index
            while index < path.count, path[index] == nil { index += 1 }
            let end = index
            guard start > 0, end < path.count, end - start <= maximumGap,
                  let left = path[start - 1], let right = path[end], abs(left - right) <= 2.5 else {
                continue
            }
            for gapIndex in start..<end {
                let fraction = Double(gapIndex - start + 1) / Double(end - start + 1)
                path[gapIndex] = left + (right - left) * fraction
            }
        }
    }

    static func resolveVerticalTransitions(
        in path: inout [Double?], verticalStroke: [Bool], maximumWidth: Int
    ) {
        guard path.count == verticalStroke.count else { return }
        var index = 0
        while index < path.count {
            guard verticalStroke[index] else { index += 1; continue }
            let start = index
            while index < path.count && verticalStroke[index] { index += 1 }
            let end = index
            guard start > 0, end < path.count, end - start <= maximumWidth,
                  let left = path[start - 1], let right = path[end], abs(left - right) > 3 else { continue }
            let center = Double(start + end) / 2
            for x in start..<end { path[x] = Double(x) < center ? left : right }
        }
    }
}

struct OCRGlucoseExtraction: Sendable {
    let samples: [OCRGlucoseSample]
    let isolatedMarkerCentersX: [Double]
    let mode: String
}

enum OCRGlucoseExtractor {
    static func isolatedMarkerCentersX(
        image: OCRPixelImage,
        plotFrame: OCRNormalizedRect,
        excludedRects: [OCRNormalizedRect]
    ) -> [Double] {
        candidateComponents(image: image, plotFrame: plotFrame, excludedRects: excludedRects)
            .map { component, crop in
                Double(crop.x) / Double(image.width) + component.centerX / Double(image.width)
            }
            .sorted()
    }

    static func extract(
        image: OCRPixelImage,
        plotFrame: OCRNormalizedRect,
        excludedRects: [OCRNormalizedRect],
        timeline: OCRTimelineMapper,
        glucoseCalibration: OCRAxisCalibration?,
        visibleMinutes: Double
    ) -> OCRGlucoseExtraction {
        let crop = image.pixelRect(for: plotFrame)
        let pixelsPerFiveMinutes = Double(crop.width) / max(1, visibleMinutes / 5)
        let candidates = candidateComponents(
            image: image,
            plotFrame: plotFrame,
            excludedRects: excludedRects,
            expectedSpacing: pixelsPerFiveMinutes
        )
        let centers = candidates.map { component, _ in
            Double(crop.x) / Double(image.width) + component.centerX / Double(image.width)
        }.sorted()
        if pixelsPerFiveMinutes >= 6 {
            let samples = candidates.compactMap { component, _ -> OCRGlucoseSample? in
                let x = Double(crop.x) / Double(image.width) + component.centerX / Double(image.width)
                let y = Double(crop.y) / Double(image.height) + component.centerY / Double(image.height)
                let rawValue = glucoseCalibration?.value(at: y)
                let value = rawValue.flatMap { (1...40).contains($0) ? $0 : nil }
                let rect = OCRPixelRect(
                    x: crop.x + component.minX,
                    y: crop.y + component.minY,
                    width: component.width,
                    height: component.height
                )
                return OCRGlucoseSample(
                    date: timeline.date(atX: x),
                    mmolPerLiter: value,
                    boundingBox: image.normalizedRect(for: rect),
                    confidence: value == nil ? 0.55 : 0.85,
                    provenance: OCRProvenance(kind: .calibratedPixelGeometry)
                )
            }
            if Double(samples.count) >= visibleMinutes / 5 * 0.98 {
                return OCRGlucoseExtraction(samples: samples, isolatedMarkerCentersX: centers, mode: "local-centers")
            }
            let windows = localWindowCenters(
                image: image, crop: crop, excludedRects: excludedRects,
                timeline: timeline, calibration: glucoseCalibration,
                visibleMinutes: visibleMinutes, isolatedCenters: centers
            )
            // Below the filled-marker diameter, isolated components represent
            // only sparse breaks in a connected trace. Merging those centres
            // would suppress genuine neighbouring window observations.
            guard !samples.isEmpty, pixelsPerFiveMinutes >= Double(image.height) * 0.016 else { return windows }
            // Half a CGM interval plus one calibrated pixel of quantization.
            // This is duplicate suppression, not the QA time-error tolerance.
            let tolerance = 150.0 + visibleMinutes * 60 / Double(max(1, crop.width))
            let additional = windows.samples.filter { window in
                !samples.contains(where: {
                    abs($0.date.timeIntervalSince(window.date)) <= tolerance
                })
            }
            // A circle straddling a bin edge can yield two window centres.
            // Retain the stronger/full-diameter section among close centres.
            var uniqueWindows: [OCRGlucoseSample] = []
            for window in additional.sorted(by: {
                if $0.boundingBox.height != $1.boundingBox.height { return $0.boundingBox.height > $1.boundingBox.height }
                return $0.date < $1.date
            }) {
                if !uniqueWindows.contains(where: { abs($0.date.timeIntervalSince(window.date)) <= tolerance }) {
                    uniqueWindows.append(window)
                }
            }
            return OCRGlucoseExtraction(samples: (samples + uniqueWindows).sorted { $0.date < $1.date },
                isolatedMarkerCentersX: centers, mode: "hybrid-local-centers")
        }

        var darkMask = darkMask(image: image, crop: crop, excludedRects: excludedRects)
        // Remove very long vertical structures before dense trace following.
        for component in OCRConnectedComponents.find(in: darkMask) where component.height > max(12, crop.height / 12) && component.width < max(10, crop.width / 150) {
            darkMask.clear(rect: OCRPixelRect(
                x: component.minX,
                y: component.minY,
                width: component.width,
                height: component.height
            ))
        }
        let binCount = max(1, Int((visibleMinutes / 5).rounded()))
        var samples: [OCRGlucoseSample] = []
        for bin in 0..<binCount {
            let startX = Int(Double(bin) / Double(binCount) * Double(crop.width))
            let endX = max(startX + 1, Int(Double(bin + 1) / Double(binCount) * Double(crop.width)))
            var points: [(x: Int, y: Int)] = []
            for x in startX..<min(crop.width, endX) {
                for y in 0..<crop.height where darkMask[x, y] {
                    points.append((x, y))
                }
            }
            guard !points.isEmpty else { continue }
            let centerX = medianInt(points.map(\.x))
            let centerY = medianInt(points.map(\.y))
            let normalizedX = Double(crop.x) / Double(image.width) + centerX / Double(image.width)
            let normalizedY = Double(crop.y) / Double(image.height) + centerY / Double(image.height)
            let rawValue = glucoseCalibration?.value(at: normalizedY)
            let value = rawValue.flatMap { (1...40).contains($0) ? $0 : nil }
            let pointRect = OCRNormalizedRect(
                x: normalizedX - 1 / Double(image.width),
                y: normalizedY - 1 / Double(image.height),
                width: 2 / Double(image.width),
                height: 2 / Double(image.height)
            )
            samples.append(
                OCRGlucoseSample(
                    date: timeline.date(atX: normalizedX),
                    mmolPerLiter: value,
                    boundingBox: pointRect,
                    confidence: value == nil ? 0.4 : 0.72,
                    provenance: OCRProvenance(kind: .pixelGeometry, note: "Dense five-minute trace mode")
                )
            )
        }
        return OCRGlucoseExtraction(samples: samples, isolatedMarkerCentersX: centers, mode: "dense-trace")
    }

    private static func localWindowCenters(
        image: OCRPixelImage, crop: OCRPixelRect,
        excludedRects: [OCRNormalizedRect], timeline: OCRTimelineMapper,
        calibration: OCRAxisCalibration?, visibleMinutes: Double,
        isolatedCenters: [Double]
    ) -> OCRGlucoseExtraction {
        let mask = darkMask(image: image, crop: crop, excludedRects: excludedRects)
        let count = max(1, Int((visibleMinutes / 5).rounded()))
        let minimumDiameter = max(3, image.height / 100)
        let maximumDiameter = max(minimumDiameter, image.height / 20)
        var samples: [OCRGlucoseSample] = []
        for bin in 0..<count {
            let start = Int(Double(bin) * Double(crop.width) / Double(count))
            let end = min(crop.width, max(start + 1, Int(Double(bin + 1) * Double(crop.width) / Double(count))))
            var runs: [(x: Int, y: Double, diameter: Int)] = []
            for x in start..<end {
                var runStart: Int?
                for y in 0...crop.height {
                    if y < crop.height && mask[x, y] {
                        if runStart == nil { runStart = y }
                    } else if let first = runStart {
                        let length = y - first
                        if (minimumDiameter...maximumDiameter).contains(length) {
                            runs.append((x, Double(first + y - 1) / 2, length))
                        }
                        runStart = nil
                    }
                }
            }
            guard let diameter = runs.map(\.diameter).max() else { continue }
            let strongest = runs.filter { $0.diameter >= diameter - 2 }
            // A marker has support across several columns; a vertical event
            // stroke must not become a glucose observation.
            guard Set(runs.map(\.x)).count >= 3 else { continue }
            let x = (Double(crop.x) + medianInt(strongest.map(\.x))) / Double(image.width)
            let y = (Double(crop.y) + medianDouble(strongest.map(\.y))) / Double(image.height)
            let value = calibration?.value(at: y)
            let accepted = value.flatMap { (1...40).contains($0) ? $0 : nil }
            samples.append(OCRGlucoseSample(
                date: timeline.date(atX: x), mmolPerLiter: accepted,
                boundingBox: OCRNormalizedRect(
                    x: x - Double(diameter) / Double(image.width) / 2,
                    y: y - Double(diameter) / Double(image.height) / 2,
                    width: Double(diameter) / Double(image.width),
                    height: Double(diameter) / Double(image.height)
                ).clampedToUnitSquare(),
                confidence: accepted == nil ? 0.4 : 0.72,
                provenance: OCRProvenance(kind: .pixelGeometry, note: "Local five-minute marker cross-section centre")
            ))
        }
        return OCRGlucoseExtraction(samples: samples, isolatedMarkerCentersX: isolatedCenters, mode: "local-window-centers")
    }

    private static func candidateComponents(
        image: OCRPixelImage,
        plotFrame: OCRNormalizedRect,
        excludedRects: [OCRNormalizedRect],
        expectedSpacing: Double? = nil
    ) -> [(OCRPixelComponent, OCRPixelRect)] {
        let crop = image.pixelRect(for: plotFrame)
        let mask = darkMask(image: image, crop: crop, excludedRects: excludedRects)
        let maximumWidth = max(22, max(crop.width / 70, image.height * 27 / 1_000))
        return OCRConnectedComponents.find(in: mask).flatMap { component -> [(OCRPixelComponent, OCRPixelRect)] in
            if let spacing = expectedSpacing, spacing >= 6,
               component.width > maximumWidth,
               component.height <= max(22, image.height * 35 / 1_000),
               component.height >= max(3, image.height / 100),
               Double(component.pixelCount) / Double(component.width * component.height) < 0.6 {
                // Hollow circles may touch and become one component. Divide
                // only observed ink, using the independently calibrated CGM
                // spacing; never fill a gap between disconnected components.
                let count = max(2, Int((Double(component.width) / spacing).rounded()))
                var fragments: [(OCRPixelComponent, OCRPixelRect)] = []
                for bin in 0..<count {
                    let left = component.minX + component.width * bin / count
                    let right = component.minX + component.width * (bin + 1) / count
                    let indices = component.pixelIndices.filter { (left..<right).contains($0 % crop.width) }
                    let xs = indices.map { $0 % crop.width }
                    let ys = indices.map { $0 / crop.width }
                    guard let minX = xs.min(), let maxX = xs.max(),
                          let minY = ys.min(), let maxY = ys.max(),
                          maxX - minX >= 2, maxY - minY >= 2,
                          indices.count >= 3 else { continue }
                    fragments.append((OCRPixelComponent(pixelIndices: indices,
                        minX: minX, maxX: maxX, minY: minY, maxY: maxY), crop))
                }
                if fragments.count == count { return fragments }
            }
            guard component.pixelCount >= 3,
                  component.pixelCount <= 450,
                  component.width >= 2,
                  component.height >= 2,
                  component.width <= maximumWidth,
                  component.height <= max(22, crop.height / 25),
                  Double(component.width) / Double(component.height) >= 0.30,
                  Double(component.width) / Double(component.height) <= 3.2 else {
                return []
            }
            return [(component, crop)]
        }
    }

    private static func darkMask(
        image: OCRPixelImage,
        crop: OCRPixelRect,
        excludedRects: [OCRNormalizedRect]
    ) -> OCRBinaryMask {
        var mask = OCRBinaryMask(width: crop.width, height: crop.height)
        for localY in 0..<crop.height {
            for localX in 0..<crop.width {
                mask[localX, localY] = image[crop.x + localX, crop.y + localY].isDarkInk
            }
        }
        for rect in excludedRects {
            let absolute = image.pixelRect(for: rect)
            mask.clear(rect: OCRPixelRect(
                x: absolute.x - crop.x - 2,
                y: absolute.y - crop.y - 2,
                width: absolute.width + 4,
                height: absolute.height + 4
            ))
        }
        return mask
    }
}

private func medianInt(_ values: [Int]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
    }
    return Double(sorted[middle])
}

private func medianDouble(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
