import Charts
import SwiftUI

struct TherapyCharts: View {
    let presentation: StoredCasePresentation
    let activityIsAvailable: Bool
    var glucoseUnit: GlucoseDisplayUnit = .mmolL

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GlucoseTherapyChart(points: presentation.glucose, unit: glucoseUnit)
            BasalEventTherapyChart(
                basal: presentation.basal,
                events: presentation.events
            )
            if activityIsAvailable && !presentation.decay.isEmpty {
                InsulinDecayTherapyChart(points: presentation.decay)
                CarbohydrateDecayTherapyChart(points: presentation.decay)
            }
        }
    }
}

private struct GlucoseTherapyChart: View, AXChartDescriptorRepresentable {
    let points: [StoredCasePresentation.GlucosePoint]
    let unit: GlucoseDisplayUnit

    nonisolated private var unitLabel: String { unit == .mgdL ? "mg/dl" : "mmol/l" }
    nonisolated private func displayed(_ mmolL: Double) -> Double {
        unit == .mgdL ? mmolL * 18 : mmolL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glukose")
                .font(.headline)
            // Interpolated column labels crash Charts' HashableText cache on
            // iOS 27. Units remain on the axis and accessibility descriptor.
            Chart(points) { point in
                LineMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Glukose", displayed(point.mmolL))
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.black)
                PointMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Glukose", displayed(point.mmolL))
                )
                .foregroundStyle(.black)
                .symbolSize(18)
            }
            .chartYAxisLabel(unitLabel)
            .chartXAxis { therapyDateAxisMarks() }
            .frame(minHeight: 210)
            .accessibilityChartDescriptor(self)
        }
    }

    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: "Glukoseverlauf",
            summary: "\(points.count) erkannte Glukosewerte bis zum Aufnahmezeitpunkt.",
            xAxis: ChartAccessibility.dateAxis(dates: points.map(\.timestamp)),
            yAxis: ChartAccessibility.numericAxis(
                title: "Glukose in \(unitLabel)",
                values: points.map { displayed($0.mmolL) },
                unit: unitLabel
            ),
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Glukose",
                    isContinuous: true,
                    dataPoints: points.map {
                        AXDataPoint(
                            x: $0.timestamp.timeIntervalSinceReferenceDate,
                            y: displayed($0.mmolL)
                        )
                    }
                ),
            ]
        )
    }
}

private struct BasalEventTherapyChart: View, AXChartDescriptorRepresentable {
    let basal: [StoredCasePresentation.BasalPoint]
    let events: [StoredCasePresentation.EventPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Basal und Ereignisse")
                .font(.headline)
            Chart {
                ForEach(basal) { point in
                    LineMark(
                        x: .value("Zeit", point.timestamp),
                        y: .value("Basalrate in IE pro Stunde", point.unitsPerHour)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                ForEach(events) { event in
                    RuleMark(x: .value("Ereigniszeit", event.timestamp))
                        .foregroundStyle(event.kind == .bolus ? .indigo : .orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, spacing: 4) {
                            EventAnnotation(event: event)
                        }
                        .accessibilityLabel(event.accessibilityDescription)
                }
            }
            .chartYAxisLabel("IE/h")
            .chartXAxis { therapyDateAxisMarks() }
            .frame(minHeight: 210)
            .accessibilityChartDescriptor(self)
        }
    }

    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        let eventSummary = events.isEmpty
            ? "Keine erkannten Bolus- oder Kohlenhydratereignisse."
            : "Zusätzlich \(events.count) erkannte Bolus- oder Kohlenhydratereignisse."
        return AXChartDescriptor(
            title: "Automatische Basalabgabe und Ereignisse",
            summary: "\(basal.count) Basal-Stützpunkte. \(eventSummary)",
            xAxis: ChartAccessibility.dateAxis(
                dates: basal.map(\.timestamp) + events.map(\.timestamp)
            ),
            yAxis: ChartAccessibility.numericAxis(
                title: "Basalrate in IE pro Stunde",
                values: basal.map(\.unitsPerHour),
                unit: "IE/h"
            ),
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Basalrate",
                    isContinuous: true,
                    dataPoints: basal.map {
                        AXDataPoint(
                            x: $0.timestamp.timeIntervalSinceReferenceDate,
                            y: $0.unitsPerHour
                        )
                    }
                ),
            ]
        )
    }
}

private struct InsulinDecayTherapyChart: View, AXChartDescriptorRepresentable {
    let points: [StoredCasePresentation.DecayPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aktives Insulin – Zukunftsabbau")
                .font(.headline)
            Chart(points) { point in
                LineMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Basal IOB in IE", point.basalIOB),
                    series: .value("Komponente", "Basal")
                )
                .foregroundStyle(by: .value("Komponente", "Basal"))
                LineMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Bolus IOB in IE", point.bolusIOB),
                    series: .value("Komponente", "Bolus")
                )
                .foregroundStyle(by: .value("Komponente", "Bolus"))
                LineMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Gesamt IOB in IE", point.totalIOB),
                    series: .value("Komponente", "Gesamt")
                )
                .foregroundStyle(by: .value("Komponente", "Gesamt"))
            }
            .chartForegroundStyleScale([
                "Basal": Color.blue,
                "Bolus": Color.indigo,
                "Gesamt": Color.purple,
            ])
            .chartYAxisLabel("IE")
            .chartXAxis { therapyDateAxisMarks() }
            .frame(minHeight: 210)
            .accessibilityChartDescriptor(self)
        }
    }

    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        let allValues = points.flatMap { [$0.basalIOB, $0.bolusIOB, $0.totalIOB] }
        return AXChartDescriptor(
            title: "Aktives Insulin im Zukunftsabbau",
            summary: "Basal-, Bolus- und Gesamt-IOB ab dem eingefrorenen Aufnahmezeitpunkt.",
            xAxis: ChartAccessibility.dateAxis(dates: points.map(\.timestamp)),
            yAxis: ChartAccessibility.numericAxis(
                title: "Aktives Insulin in IE",
                values: allValues,
                unit: "IE"
            ),
            additionalAxes: [],
            series: [
                ChartAccessibility.series(name: "Basal IOB", points: points) { $0.basalIOB },
                ChartAccessibility.series(name: "Bolus IOB", points: points) { $0.bolusIOB },
                ChartAccessibility.series(name: "Gesamt IOB", points: points) { $0.totalIOB },
            ]
        )
    }
}

private struct CarbohydrateDecayTherapyChart: View, AXChartDescriptorRepresentable {
    let points: [StoredCasePresentation.DecayPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aktive Kohlenhydrate – Zukunftsabbau")
                .font(.headline)
            Chart(points) { point in
                AreaMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Aktive Kohlenhydrate in Gramm", point.carbohydratesOnBoard)
                )
                .foregroundStyle(.orange.opacity(0.25))
                LineMark(
                    x: .value("Zeit", point.timestamp),
                    y: .value("Aktive Kohlenhydrate in Gramm", point.carbohydratesOnBoard)
                )
                .foregroundStyle(.orange)
            }
            .chartYAxisLabel("g")
            .chartXAxis { therapyDateAxisMarks() }
            .frame(minHeight: 190)
            .accessibilityChartDescriptor(self)
        }
    }

    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: "Aktive Kohlenhydrate im Zukunftsabbau",
            summary: "Berechnete aktive Kohlenhydrate ab dem eingefrorenen Aufnahmezeitpunkt.",
            xAxis: ChartAccessibility.dateAxis(dates: points.map(\.timestamp)),
            yAxis: ChartAccessibility.numericAxis(
                title: "Aktive Kohlenhydrate",
                values: points.map(\.carbohydratesOnBoard),
                unit: "g"
            ),
            additionalAxes: [],
            series: [
                ChartAccessibility.series(
                    name: "Aktive Kohlenhydrate",
                    points: points
                ) { $0.carbohydratesOnBoard },
            ]
        )
    }
}

@AxisContentBuilder
private func therapyDateAxisMarks() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) {
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.hour().minute())
    }
}

private struct EventAnnotation: View {
    let event: StoredCasePresentation.EventPoint

    var body: some View {
        let prefix = event.kind == .bolus ? "B" : "KH"
        let value = event.amount.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "?"
        Text("\(prefix) \(value)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(event.kind == .bolus ? .indigo : .orange)
    }
}

private enum ChartAccessibility {
    static func dateAxis(dates: [Date]) -> AXNumericDataAxisDescriptor {
        let first = dates.min() ?? .now
        let lastCandidate = dates.max() ?? first.addingTimeInterval(60)
        let last = lastCandidate > first ? lastCandidate : first.addingTimeInterval(60)
        return AXNumericDataAxisDescriptor(
            title: "Zeit",
            range: first.timeIntervalSinceReferenceDate ... last.timeIntervalSinceReferenceDate,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSinceReferenceDate: value)
                .formatted(date: .abbreviated, time: .shortened)
        }
    }

    static func numericAxis(
        title: String,
        values: [Double],
        unit: String
    ) -> AXNumericDataAxisDescriptor {
        let minimum = min(0, values.min() ?? 0)
        let maximumCandidate = values.max() ?? 1
        let maximum = maximumCandidate > minimum ? maximumCandidate : minimum + 1
        return AXNumericDataAxisDescriptor(
            title: title,
            range: minimum ... maximum,
            gridlinePositions: []
        ) { value in
            "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
        }
    }

    static func series(
        name: String,
        points: [StoredCasePresentation.DecayPoint],
        value: (StoredCasePresentation.DecayPoint) -> Double
    ) -> AXDataSeriesDescriptor {
        AXDataSeriesDescriptor(
            name: name,
            isContinuous: true,
            dataPoints: points.map {
                AXDataPoint(
                    x: $0.timestamp.timeIntervalSinceReferenceDate,
                    y: value($0)
                )
            }
        )
    }
}

private extension StoredCasePresentation.EventPoint {
    var accessibilityDescription: String {
        let type = kind == .bolus ? "Bolus" : "Kohlenhydrate"
        let unit = kind == .bolus ? "IE" : "Gramm"
        let amountDescription = amount.map {
            "\($0.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
        } ?? "Menge unbekannt"
        return "\(type), \(amountDescription), \(timestamp.formatted(date: .omitted, time: .shortened))"
    }
}
