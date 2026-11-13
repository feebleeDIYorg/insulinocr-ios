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

/// What the ink of a pill label consists of, independent of text recognition.
struct OCRLabelGlyphShape: Sendable, Equatable {
    let digits: Int
    let separators: Int
    let unit: OCRTherapyEventKind

    /// A unit-less reading is complete when it accounts for every number
    /// glyph in the pill and the unit glyphs belong to the expected kind.
    func confirms(bareNumber text: String, kind: OCRTherapyEventKind) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        return kind == unit
            && characters.filter(\.isNumber).count == digits
            && characters.filter { $0 == "." || $0 == "," }.count == separators
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

    /// The capture marker is a darker rule than any gridline. A clock label
    /// within the search radius would otherwise snap to it, so its columns and
    /// anti-aliased edges never count as raster evidence.
    static func alignTimeAnchors(
        _ anchors: [OCRTimeAnchor], image: OCRPixelImage, frame: OCRNormalizedRect,
        captureMarker: OCRNormalizedRect? = nil
    ) -> [OCRTimeAnchor] {
        let bounds = image.pixelRect(for: frame)
        let markerColumns = captureMarker.map { marker -> ClosedRange<Int> in
            let rect = image.pixelRect(for: marker)
            return (rect.x - 2)...(rect.maxX + 1)
        }
        return anchors.map { anchor in
            let center = Int(anchor.x * Double(image.width))
            let radius = max(2, image.width / 120)
            var columnScores: [(x: Int, count: Int, contrast: Int)] = []
            let lower = max(bounds.x, center - radius), upper = min(bounds.maxX - 1, center + radius)
            guard lower <= upper else { return anchor }
            for x in lower...upper where markerColumns?.contains(x) != true {
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
    ) throws -> (plotFrame: OCRNormalizedRect, dataRightEdgeX: Double, confidence: Double, captureMarker: OCRNormalizedRect?) {
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
        let marker = try captureMarker(image: image, frame: frame)
        let observedRight = futurePanelBoundary(image: image, frame: frame) ?? normalizedRight
        let dataRightEdge = marker?.minX ?? min(frame.maxX, max(minimumUsableRight, observedRight))
        let confidence = min(1, 0.55 + min(0.2, Double(anchors.count) * 0.04)
            + min(0.15, Double(blueCount) / 2_000)
            + min(0.1, Double(darkCount) / 4_000))
        return (frame, dataRightEdge, confidence, marker)
    }

    /// A solid neutral rule with historical white basal background on its left
    /// and the shaded future panel on its right. Gridlines lack this transition.
    static func captureMarker(image: OCRPixelImage, frame: OCRNormalizedRect) throws -> OCRNormalizedRect? {
        let b = image.pixelRect(for: frame)
        guard b.width > 12, b.height > 20 else { return nil }
        func neutral(_ c: OCRPixelColor) -> Bool {
            abs(Int(c.red) - Int(c.green)) <= 8 && abs(Int(c.red) - Int(c.blue)) <= 8
        }
        func fraction(_ x: Int, lower: Bool, matches: (OCRPixelColor) -> Bool) -> Double {
            let start = lower ? b.y + b.height * 2 / 3 : b.y + 3
            let ys = stride(from: start, to: b.maxY - 3, by: 3)
            var count = 0, total = 0
            for y in ys { total += 1; if matches(image[x, y]) { count += 1 } }
            return Double(count) / Double(max(1, total))
        }
        var candidates: [OCRNormalizedRect] = []
        var x = b.x + 4
        while x < b.maxX - 4 {
            let isRule: (OCRPixelColor) -> Bool = { neutral($0) && (100...190).contains(Int($0.red)) }
            guard fraction(x, lower: false, matches: isRule) >= 0.85 else { x += 1; continue }
            let start = x
            while x < b.maxX - 3 && fraction(x, lower: false, matches: isRule) >= 0.85 { x += 1 }
            guard (2...max(6, image.width / 150)).contains(x - start), start >= b.x + 3,
                  fraction(start - 2, lower: true, matches: { neutral($0) && $0.red >= 235 }) >= 0.8,
                  fraction(x + 1, lower: true, matches: { neutral($0) && (190...225).contains(Int($0.red)) }) >= 0.8
            else { continue }
            candidates.append(image.normalizedRect(for: .init(x: start, y: b.y, width: x - start, height: b.height)))
        }
        // Conflicting boundaries are not resolved by guessing a later time.
        guard candidates.count <= 1 else {
            throw OCRAnalysisFailure.unsupportedLayout(reason: "Multiple capture boundaries require review.")
        }
        return candidates.first
    }

    static func futurePanelBoundary(image: OCRPixelImage, frame: OCRNormalizedRect) -> Double? {
        let bounds = image.pixelRect(for: frame)
        // Panel evidence must exceed a gridline's display-scale thickness.
        // A fraction of chart width rejects short future intervals on long charts.
        let maximumGridlineGap = max(4, image.width / 300)
        let minimumWidth = maximumGridlineGap * 2
        let edgeTolerance = max(12, bounds.width / 30)
        var panelRight: Int?
        var panelLeft: Int?
        var gap = 0
        var panelColumns = 0
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
                panelColumns += 1
                gap = 0
            } else if let right = panelRight, let left = panelLeft {
                // Thin vertical gridlines also cross the future panel.
                gap += 1
                if gap <= maximumGridlineGap { continue }
                guard right - left + 1 >= minimumWidth,
                      panelColumns >= minimumWidth else { return nil }
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
            let colourKind: OCRTherapyEventKind
            if blue > max(3, orange * 2) {
                colourKind = .bolus
            } else if orange > max(3, blue * 2) {
                colourKind = .carbohydrates
            } else {
                colourKind = .unknown
            }
            let normalizedStem = image.normalizedRect(for: stemPixelRect)
            // CamAPS draws neutral stems; the label row carries the kind.
            let kind = colourKind == .unknown
                ? labelRowKind(stemTop: normalizedStem.minY, frame: plotFrame) : colourKind
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
                confidence: 0.55 + lengthConfidence * 0.35 + (colourKind == .unknown ? 0 : 0.1)
            )
        }
        return isolatePillRegions(dropStemsBehindNeighbouringPill(
            recoverStackedBolusStems(stems, image: image, frame: plotFrame), image: image))
    }

    /// A bolus stem can run down behind the carbohydrate pill of an event one
    /// or two minutes away. Its lower part then looks like a second stem under
    /// that pill and would split the label between both. The lower part is
    /// dropped only when the stem already carries its own upper pill and the
    /// pill outline above is centred on exactly one neighbour instead.
    static func dropStemsBehindNeighbouringPill(
        _ stems: [OCRDetectedEventStem], image: OCRPixelImage
    ) -> [OCRDetectedEventStem] {
        let width = Double(image.width), height = Double(image.height)
        func sameColumn(_ a: OCRDetectedEventStem, _ b: OCRDetectedEventStem) -> Bool {
            abs(a.stemRect.midX - b.stemRect.midX) < 3 / width
        }
        return stems.filter { stem in
            guard stem.isComplete, stems.contains(where: {
                $0.isComplete && sameColumn($0, stem) && $0.stemRect.minY < stem.stemRect.minY - 0.015
            }) else { return true }
            // Closer than one pill height: both cannot own a pill on this row.
            let neighbours = stems.filter {
                $0.isComplete && !sameColumn($0, stem)
                    && abs($0.stemRect.minY - stem.stemRect.minY) < 0.015
                    && abs($0.stemRect.midX - stem.stemRect.midX) * width < 0.045 * height
            }
            guard neighbours.count == 1,
                  let center = pillBaseCenterX(above: stem, image: image) else { return true }
            return !(abs(center - neighbours[0].stemRect.midX * width) <= 1.5
                && abs(center - stem.stemRect.midX * width) >= 2.5)
        }
    }

    /// Pixel centre of the flat light-grey pill outline directly above a stem.
    /// Lower edge of the upper label row, measured up from the plot frame.
    /// Lower-row stems end about 0.016 above the frame, upper-row stems about 0.07.
    static let upperLabelRowOffset = 0.04

    /// CamAPS FX layout assumption: bolus pills sit on the upper label row,
    /// carbohydrate pills on the lower one. A stem ending in the upper row is
    /// therefore a bolus and one ending in the lower row a carbohydrate entry.
    /// The recognized unit must still agree (`OCRTextParser.unitContradicts`).
    static func labelRowKind(stemTop: Double, frame: OCRNormalizedRect) -> OCRTherapyEventKind {
        stemTop < frame.minY - upperLabelRowOffset ? .bolus : .carbohydrates
    }

    private static func isPillOutline(_ color: OCRPixelColor) -> Bool {
        let low = min(color.red, color.green, color.blue)
        let high = max(color.red, color.green, color.blue)
        return low >= 170 && high <= 240 && high - low <= 16
    }

    /// Widest light-grey outline run directly above the stem top.
    static func pillBaseRun(
        above stem: OCRDetectedEventStem, image: OCRPixelImage
    ) -> (lower: Int, upper: Int, y: Int)? {
        let rect = image.pixelRect(for: stem.stemRect)
        let column = rect.x + rect.width / 2
        var best: (lower: Int, upper: Int, y: Int)?
        for y in max(0, rect.y - 3)..<rect.y where isPillOutline(image[column, y]) {
            var lower = column, upper = column
            while lower > 0, isPillOutline(image[lower - 1, y]) { lower -= 1 }
            while upper < image.width - 1, isPillOutline(image[upper + 1, y]) { upper += 1 }
            if upper - lower > (best.map { $0.upper - $0.lower } ?? 0) { best = (lower, upper, y) }
        }
        // A pill base is far wider than a stem; anything shorter is no outline.
        guard let run = best, run.upper - run.lower >= max(12, image.height / 60) else { return nil }
        return run
    }

    static func pillBaseCenterX(above stem: OCRDetectedEventStem, image: OCRPixelImage) -> Double? {
        pillBaseRun(above: stem, image: image).map { Double($0.lower + $0.upper + 1) / 2 }
    }

    /// Measured bounds of the pill above a stem, only when its outline is
    /// closed: flat base and top, both end arcs, and paper beyond each arc.
    /// An outline cut by a neighbouring pill or an image edge returns nil.
    static func closedPillRect(above stem: OCRDetectedEventStem, image: OCRPixelImage) -> OCRNormalizedRect? {
        closedPillPixelRect(above: stem, image: image).map(image.normalizedRect(for:))
    }

    static func closedPillPixelRect(above stem: OCRDetectedEventStem, image: OCRPixelImage) -> OCRPixelRect? {
        guard let base = pillBaseRun(above: stem, image: image) else { return nil }
        let needed = (base.upper - base.lower + 1) * 4 / 5
        var top: Int?
        let nearest = base.y - Int(Double(image.height) * 0.02)
        let farthest = max(0, base.y - Int(Double(image.height) * 0.07))
        guard nearest > farthest else { return nil }
        for y in stride(from: nearest, to: farthest, by: -1) {
            var count = 0
            for x in base.lower...base.upper where isPillOutline(image[x, y]) { count += 1 }
            if count >= needed { top = y } else if top != nil { break }
        }
        guard let top else { return nil }
        let radius = (base.y - top + 1) / 2, middle = (base.y + top) / 2
        let stemRect = image.pixelRect(for: stem.stemRect)
        // Twice the stem centre, to stay in whole pixels.
        let doubledCentre = 2 * stemRect.x + stemRect.width
        func isPaper(_ x: Int, _ y: Int) -> Bool {
            guard (0..<image.width).contains(x) else { return false }
            let color = image[x, y]
            return min(color.red, color.green, color.blue) >= 245
        }
        func arcEnd(from start: Int, step: Int) -> Int? {
            var last: Int?
            for offset in 1..<(radius + 5) {
                let x = start + step * offset
                guard (0..<image.width).contains(x) else { return nil }
                if isPillOutline(image[x, middle]) { last = x }
            }
            guard let last else { return nil }
            for offset in 2..<6 where !isPaper(last + step * offset, middle) { return nil }
            return last
        }
        // A pill is centred on its stem. Where two pills overlap, their flat
        // rows merge and the arcs found from the run ends belong to different
        // pills; such a span is not centred and is no measurement.
        if let left = arcEnd(from: base.lower, step: -1),
           let right = arcEnd(from: base.upper, step: 1),
           abs(left + right + 1 - doubledCentre) <= 3 {
            return OCRPixelRect(x: left, y: top, width: right - left + 1, height: base.y - top + 1)
        }
        return frontPillPixelRect(doubledCentre: doubledCentre, top: top, baseY: base.y, image: image)
    }

    /// The pill drawn in front of an overlapping neighbour keeps both end
    /// arcs. It is found as the one span that is symmetric about the stem
    /// and has an outline arc at three heights on each side, with paper
    /// outside the right arc and inside both. A pill behind its neighbour
    /// has a hidden arc and therefore no such span.
    private static func frontPillPixelRect(
        doubledCentre: Int, top: Int, baseY: Int, image: OCRPixelImage
    ) -> OCRPixelRect? {
        let pillHeight = baseY - top + 1
        let radius = Double(pillHeight) / 2, middle = (baseY + top) / 2
        func isPaper(_ x: Int, _ y: Int) -> Bool {
            guard (0..<image.width).contains(x) else { return false }
            let color = image[x, y]
            return min(color.red, color.green, color.blue) >= 245
        }
        func outlineNear(_ x: Int, _ y: Int) -> Bool {
            (-1...1).contains { (0..<image.width).contains(x + $0) && isPillOutline(image[x + $0, y]) }
        }
        let centre = doubledCentre / 2
        let first = centre + Int(radius), last = min(image.width - 6, centre + Int(2.2 * Double(pillHeight)))
        guard first <= last else { return nil }
        var ends: [Int] = []
        for right in first...last where isPillOutline(image[right, middle]) {
            let left = doubledCentre - 1 - right
            guard left >= 6,
                  (2..<6).allSatisfy({ isPaper(right + $0, middle) }),
                  (3..<6).allSatisfy({ isPaper(right - $0, middle) && isPaper(left + $0, middle) }),
                  outlineNear(left, middle) else { continue }
            let arcsMatch = [-0.5, 0.5].allSatisfy { fraction -> Bool in
                let y = Int((Double(middle) + fraction * radius).rounded())
                let inset = radius - (radius * radius - (fraction * radius) * (fraction * radius)).squareRoot()
                return outlineNear(Int((Double(right) - inset).rounded()), y)
                    && outlineNear(Int((Double(left) + inset).rounded()), y)
            }
            if arcsMatch { ends.append(right) }
        }
        guard let right = ends.max(), let innermost = ends.min(), right - innermost <= 2 else { return nil }
        let left = doubledCentre - 1 - right
        return OCRPixelRect(x: left, y: top, width: right - left + 1, height: pillHeight)
    }

    /// Part of a measured pill that can only hold its own label: the label
    /// starts well inside the end arcs, and a neighbour's glyphs can reach
    /// into the rectangle only next to them.
    static func labelRegion(of pill: OCRPixelRect) -> OCRPixelRect {
        let inset = min(pill.width / 3, max(3, pill.height / 5))
        return OCRPixelRect(x: pill.x + inset, y: pill.y, width: pill.width - 2 * inset, height: pill.height)
    }

    /// Glyph structure of the label inside a closed pill, from ink alone.
    ///
    /// CamAPS sets "<number> <unit>": glyphs are ink columns separated by
    /// paper, and exactly one gap is as wide as a space. Left of it stand
    /// digits and at most narrow decimal separators, right of it the unit:
    /// one wide glyph ("g") or a narrow and a wide one ("IE"). All widths
    /// are relative to the pill height. Anything else returns nil: merged
    /// or split glyphs, a second pill's text, a cut or foreign label.
    static func labelGlyphShape(above stem: OCRDetectedEventStem, image: OCRPixelImage) -> OCRLabelGlyphShape? {
        guard let pill = closedPillPixelRect(above: stem, image: image), pill.height >= 12 else { return nil }
        let inset = max(3, pill.height / 12)
        let label = labelRegion(of: pill)
        guard label.width > 2 else { return nil }
        let unit = Double(pill.height)
        var groups: [(first: Int, last: Int)] = []
        for x in label.x...(label.maxX - 1) {
            var hasInk = false
            for y in (pill.y + inset)...(pill.maxY - 1 - inset) {
                let color = image[x, y]
                if color.isDarkInk || color.isTherapyBlue { hasInk = true; break }
            }
            guard hasInk else { continue }
            if let last = groups.last, last.last == x - 1 {
                groups[groups.count - 1].last = x
            } else {
                groups.append((x, x))
            }
        }
        guard groups.count >= 2 else { return nil }
        let widths = groups.map { Double($0.last - $0.first + 1) / unit }
        let gaps = zip(groups, groups.dropFirst()).map { Double($1.first - $0.last - 1) / unit }
        let spaces = gaps.indices.filter { gaps[$0] >= 0.2 }
        guard spaces.count == 1, let space = spaces.first else { return nil }
        func isWideGlyph(_ width: Double) -> Bool { (0.25...0.45).contains(width) }
        let unitWidths = Array(widths[(space + 1)...])
        let kind: OCRTherapyEventKind
        if unitWidths.count == 1, isWideGlyph(unitWidths[0]) {
            kind = .carbohydrates
        } else if unitWidths.count == 2, unitWidths[0] <= 0.12, isWideGlyph(unitWidths[1]),
                  gaps[space + 1] <= 0.18 {
            kind = .bolus
        } else {
            return nil
        }
        var digits = 0, separators = 0
        for width in widths[...space] {
            if width <= 0.12 {
                separators += 1
            } else if (0.14...0.45).contains(width) {
                digits += 1
            } else {
                return nil
            }
        }
        return OCRLabelGlyphShape(digits: digits, separators: separators, unit: kind)
    }

    /// Another stem on the same label row close enough that the two pills
    /// can overlap; the crop of either may then cut the other's glyphs.
    static func hasCompetingNeighbour(_ stem: OCRDetectedEventStem, among stems: [OCRDetectedEventStem]) -> Bool {
        stems.contains {
            $0.stemRect != stem.stemRect
                && abs($0.stemRect.minY - stem.stemRect.minY) < 0.015
                && abs($0.stemRect.midX - stem.stemRect.midX) < 0.08
        }
    }

    static func recoverStackedBolusStems(
        _ stems: [OCRDetectedEventStem], image: OCRPixelImage, frame: OCRNormalizedRect
    ) -> [OCRDetectedEventStem] {
        var result = stems
        for lower in stems where lower.isComplete && lower.stemRect.minY > frame.minY - upperLabelRowOffset {
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
                for px in bounds.x..<min(bounds.maxX, Int((frame.maxX * Double(image.width)).rounded(.down)))
                    where image[px, y].isTherapyBlue { blue += 1 }
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
        rateCalibration: OCRAxisCalibration?,
        captureMarkerEndDate: Date? = nil
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
            let markerEnd = run.end == crop.width ? captureMarkerEndDate : nil
            let reachesCaptureMarker = markerEnd != nil
            let endDate = markerEnd ?? timeline.date(atX: endX)
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
                    note: rate == nil ? "Basal geometry found, but rate-axis calibration is unavailable." :
                        (reachesCaptureMarker ? "Observed basal path touches capture marker; its endpoint is capture time. Marker stroke and future panel are excluded." : nil)
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
