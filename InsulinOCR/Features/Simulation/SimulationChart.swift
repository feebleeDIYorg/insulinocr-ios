import Charts
import InsulinOCRCore
import SwiftUI

/// One chart for glucose, insulin on board and carbohydrates on board.
/// Glucose uses the left axis; insulin and carbohydrates are mapped onto it
/// and labelled on the right axis (10 g of carbohydrate = 1 unit).
struct SimulationChart: View {
    let data: SimulationChartData
    let limits: GlucoseLimits
    let unit: GlucoseDisplayUnit
    let showBaseline: Bool
    let visibleOrefCurves: Set<OrefCurveKind>

    @State private var selectedDate: Date?

    private struct Line: Identifiable {
        let id: String
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
        let samples: [SimulationChartData.Sample]
    }

    private struct Marker: Identifiable {
        let id: UUID
        let date: Date
        let color: Color
    }

    private struct Band: Identifiable {
        let id: UUID
        let start: Date
        let end: Date
    }

    private var glucoseScale: Double { unit == .mgdL ? 18 : 1 }

    private var scale: SimulationChartScale {
        let shown = data.scenario + (showBaseline ? data.baseline : [])
        let glucose = shown.compactMap(\.glucose) + data.measured.map(\.value)
            + data.orefCurves.filter { visibleOrefCurves.contains($0.kind) }.flatMap { $0.samples.map(\.value) }
        return SimulationChartScale(
            maxGlucose: max(glucose.max() ?? 0, limits.hyper) * glucoseScale,
            maxIOB: shown.map(\.iob).max() ?? 0,
            maxCOB: shown.map(\.cob).max() ?? 0,
            displayScale: glucoseScale)
    }

    private var domainStart: Date {
        data.reference.addingTimeInterval(-SimulationChartBuilder.historyMinutes * 60)
    }

    private var domainEnd: Date {
        let ends = [data.scenario.last?.date, showBaseline ? data.baseline.last?.date : nil].compactMap { $0 }
        return ends.max() ?? data.reference.addingTimeInterval(21_600)
    }

    private func glucoseSamples(_ points: [SimulationChartData.Point]) -> [SimulationChartData.Sample] {
        points.compactMap { point -> SimulationChartData.Sample? in
            guard let glucose = point.glucose else { return nil }
            return SimulationChartData.Sample(date: point.date, value: glucose * glucoseScale)
        }
    }

    private var lines: [Line] {
        let scale = self.scale
        var result: [Line] = []
        func activity(_ points: [SimulationChartData.Point], suffix: String, dash: [CGFloat]) {
            result.append(Line(id: "iob" + suffix, color: .blue, width: 1.5, dash: dash,
                samples: points.map { SimulationChartData.Sample(date: $0.date, value: scale.position(units: $0.iob)) }))
            result.append(Line(id: "cob" + suffix, color: .orange, width: 1.5, dash: dash,
                samples: points.map { SimulationChartData.Sample(date: $0.date, value: scale.position(grams: $0.cob)) }))
        }
        activity(data.scenario, suffix: "", dash: [])
        if showBaseline {
            activity(data.baseline, suffix: "-base", dash: [5, 4])
            result.append(Line(id: "glucose-base", color: .secondary, width: 2, dash: [5, 4],
                               samples: glucoseSamples(data.baseline)))
        }
        for curve in data.orefCurves where visibleOrefCurves.contains(curve.kind) {
            result.append(Line(id: "oref-" + curve.kind.rawValue, color: Self.color(curve.kind), width: 1.5,
                dash: [2, 3], samples: curve.samples.map {
                    SimulationChartData.Sample(date: $0.date, value: $0.value * glucoseScale)
                }))
        }
        // Scaled limits, so the zones are found in the display unit.
        let scaledLimits = GlucoseLimits(
            hypo: limits.hypo * glucoseScale, targetLow: limits.targetLow * glucoseScale,
            targetHigh: limits.targetHigh * glucoseScale, hyper: limits.hyper * glucoseScale)
        for run in SimulationChartData.zoneRuns(glucoseSamples(data.scenario), limits: scaledLimits) {
            let color: Color = switch run.zone {
            case .low: .red
            case .inRange: .primary
            case .high: .yellow
            }
            result.append(Line(id: "glucose-" + String(run.index), color: color, width: 2.5, dash: [],
                               samples: run.samples))
        }
        return result
    }

    private var markers: [Marker] {
        data.events.compactMap { event -> Marker? in
            switch event {
            case .bolus: return Marker(id: event.id, date: event.date, color: .indigo)
            case .carbohydrate: return Marker(id: event.id, date: event.date, color: .orange)
            case .insulinNeed: return nil
            }
        }
    }

    private var bands: [Band] {
        data.events.compactMap { event -> Band? in
            guard case .insulinNeed(let adjustment) = event else { return nil }
            return Band(id: adjustment.id, start: max(adjustment.startDate, domainStart),
                        end: min(adjustment.endDate, domainEnd))
        }.filter { $0.end > $0.start }
    }

    /// The point nearest to the touched time; the reference point otherwise.
    private var readoutPoint: SimulationChartData.Point? {
        guard let selectedDate else { return data.scenario.first }
        return data.scenario.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            HStack {
                Text(unit.label)
                Spacer()
                Text("IE · KH ÷ 10 g")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            chart
            legend
            if let reason = data.missingGlucoseReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readout: some View {
        HStack(spacing: 10) {
            if let point = readoutPoint {
                Text(point.date, format: .dateTime.hour().minute())
                if let glucose = point.glucose {
                    Text(Self.number(glucose * glucoseScale, digits: unit == .mgdL ? 0 : 1) + " " + unit.label)
                }
                Text("IOB " + Self.number(point.iob, digits: 2) + " IE")
                Text("KH " + Self.number(point.cob, digits: 0) + " g")
            }
        }
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("simulation.readout")
    }

    private var chart: some View {
        let scale = self.scale
        return Chart {
            RectangleMark(
                xStart: .value("Zeit", domainStart), xEnd: .value("Zeit", domainEnd),
                yStart: .value("Zielbereich", limits.targetLow * glucoseScale),
                yEnd: .value("Zielbereich", limits.targetHigh * glucoseScale)
            )
            .foregroundStyle(Color.green.opacity(0.10))
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Zeit", band.start), xEnd: .value("Zeit", band.end),
                    yStart: .value("Aktivität", 0), yEnd: .value("Aktivität", scale.glucoseMax)
                )
                .foregroundStyle(Color.purple.opacity(0.08))
            }
            RuleMark(x: .value("Jetzt", data.reference))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(markers) { marker in
                RuleMark(x: .value("Ereignis", marker.date))
                    .foregroundStyle(marker.color.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(data.measured) { sample in
                PointMark(x: .value("Zeit", sample.date), y: .value("Glukose", sample.value * glucoseScale))
                    .foregroundStyle(Color.primary)
                    .symbolSize(14)
            }
            ForEach(lines) { line in
                ForEach(line.samples) { sample in
                    LineMark(
                        x: .value("Zeit", sample.date),
                        y: .value("Wert", sample.value),
                        series: .value("Reihe", line.id)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: line.width, dash: line.dash))
                }
            }
            if let selectedDate {
                RuleMark(x: .value("Auswahl", selectedDate))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: 0...scale.glucoseMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
            AxisMarks(position: .trailing, values: scale.rightTickPositions) { value in
                AxisTick()
                AxisValueLabel {
                    if let position = value.as(Double.self) {
                        Text(Self.number(scale.units(atPosition: position), digits: scale.unitsMax < 4 ? 1 : 0))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 300)
        .accessibilityLabel("Simulierter Verlauf von Glukose, aktivem Insulin und aktiven Kohlenhydraten")
        .accessibilityIdentifier("simulation.chart")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            if data.missingGlucoseReason == nil {
                legendItem("Glukose", color: .primary)
            }
            legendItem("IOB", color: .blue)
            legendItem("KH", color: .orange)
            if showBaseline {
                Text("gestrichelt: Basis")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title)
        }
    }

    static func color(_ kind: OrefCurveKind) -> Color {
        switch kind {
        case .insulinOnly: .teal
        case .withCarbohydrates: .brown
        case .zeroTemp: .gray
        }
    }

    private static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}
