import Charts
import InsulinOCRCore
import SwiftUI

struct SimulationView: View {
    @Environment(\.dismiss) private var dismiss
    let record: CaseEntity
    let library: CaseLibraryStore

    @State private var baseEnvelope: StoredComputationEnvelope?
    @State private var scenarioName = "Neue Simulation"
    @State private var eventTime: Date
    @State private var bolusUnits = 0.0
    @State private var carbohydrateGrams = 0.0
    @State private var preview: SimulationScenario?
    @State private var savedScenarios: [SimulationScenario] = []
    @State private var errorMessage: String?

    init(record: CaseEntity, library: CaseLibraryStore) {
        self.record = record
        self.library = library
        self.eventTime = record.captureTime
    }

    private var canSimulate: Bool {
        record.status == .complete
            && baseEnvelope?.presentation.isComplete == true
            && baseEnvelope?.run.id == record.activeComputationRunID
    }

    var body: some View {
        NavigationStack {
            Form {
                if canSimulate {
                    inputSection
                    if let preview {
                        resultSection(preview)
                    }
                    savedSection
                } else {
                    ContentUnavailableView(
                        "Simulation nicht verfügbar",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Der Case benötigt eine vollständige und bestätigte Berechnung.")
                    )
                }
            }
            .navigationTitle("Simulation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Szenario speichern") { saveScenario() }
                        .disabled(!canSimulate || preview == nil)
                }
            }
            .task(id: record.activeComputationRunID) { load() }
            .onChange(of: record.status) { updatePreview() }
            .onChange(of: bolusUnits) { updatePreview() }
            .onChange(of: carbohydrateGrams) { updatePreview() }
            .onChange(of: eventTime) { updatePreview() }
            .onChange(of: scenarioName) { updatePreview() }
            .alert(
                "Simulation nicht verfügbar",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var inputSection: some View {
        Section {
            TextField("Name", text: $scenarioName)
                .accessibilityIdentifier("simulation.name")
            DatePicker("Zeitpunkt", selection: $eventTime, in: ...record.captureTime)
            HStack {
                Text("Zusätzlicher Bolus")
                Spacer(minLength: 8)
                TextField("IE", value: $bolusUnits, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 96)
                    .accessibilityLabel("Zusätzlicher Bolus")
                    .accessibilityIdentifier("simulation.bolus")
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Zusätzliche Kohlenhydrate")
                Spacer(minLength: 8)
                TextField("g", value: $carbohydrateGrams, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 96)
                    .accessibilityLabel("Zusätzliche Kohlenhydrate")
                    .accessibilityIdentifier("simulation.carbs")
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Was-wäre-wenn-Ereignisse")
        } footer: {
            Text("Simulationen bleiben getrennt von erkannten und korrigierten Therapiedaten. Der Zeitpunkt liegt spätestens beim eingefrorenen Aufnahmezeitpunkt.")
        }
    }

    private func resultSection(_ scenario: SimulationScenario) -> some View {
        return Section("Basis, Szenario und Delta") {
            comparisonRows(scenario)
            if let envelope = baseEnvelope {
                SimulationForecastChart(envelope: envelope, scenario: scenario)
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !savedScenarios.isEmpty {
            Section("Gespeicherte Szenarien") {
                ForEach(savedScenarios) { scenario in
                    DisclosureGroup {
                        comparisonRows(scenario)
                            .padding(.vertical, 6)
                        if let envelope = envelope(for: scenario) {
                            SimulationForecastChart(envelope: envelope, scenario: scenario)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scenario.name)
                                .font(.headline)
                            Text(scenario.createdAt, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comparisonRows(_ scenario: SimulationScenario) -> some View {
        let delta = SimulationDelta(baseline: scenario.baseline, scenario: scenario.scenario)
        SimulationComparisonRow(
            title: "Basal IOB",
            baseline: scenario.baseline.basalIOB.value,
            scenario: scenario.scenario.basalIOB.value,
            delta: delta.basalIOB,
            unit: "IE"
        )
        SimulationComparisonRow(
            title: "Bolus IOB",
            baseline: scenario.baseline.bolusIOB.value,
            scenario: scenario.scenario.bolusIOB.value,
            delta: delta.bolusIOB,
            unit: "IE"
        )
        SimulationComparisonRow(
            title: "Gesamt IOB",
            baseline: scenario.baseline.totalIOB.value,
            scenario: scenario.scenario.totalIOB.value,
            delta: delta.totalIOB,
            unit: "IE"
        )
        SimulationComparisonRow(
            title: "Aktive KH",
            baseline: scenario.baseline.cob.value,
            scenario: scenario.scenario.cob.value,
            delta: delta.cob,
            unit: "g"
        )
    }

    private func load() {
        baseEnvelope = nil
        preview = nil
        savedScenarios = []
        guard let runID = record.activeComputationRunID,
              let entity = try? library.computationRuns(caseID: record.id).first(where: { $0.id == runID }),
              let envelope = try? JSONDecoder.insulinOCR.decode(
                  StoredComputationEnvelope.self,
                  from: entity.encodedPayload
              ) else {
            errorMessage = "Kein aktiver Rechenlauf vorhanden."
            return
        }
        baseEnvelope = envelope
        savedScenarios = (try? library.simulations(caseID: record.id))?.compactMap {
            try? JSONDecoder.insulinOCR.decode(SimulationScenario.self, from: $0.encodedPayload)
        } ?? []
        updatePreview()
    }

    private func envelope(for scenario: SimulationScenario) -> StoredComputationEnvelope? {
        guard let entity = try? library.computationRuns(caseID: record.id).first(where: {
            $0.id == scenario.baseComputationRunID
        }) else { return nil }
        return try? JSONDecoder.insulinOCR.decode(StoredComputationEnvelope.self, from: entity.encodedPayload)
    }

    private func updatePreview() {
        guard canSimulate, let envelope = baseEnvelope else {
            preview = nil
            return
        }
        var events: [SimulationEvent] = []
        if bolusUnits > 0, bolusUnits.isFinite {
            events.append(.bolus(InsulinEvent(date: eventTime, units: bolusUnits)))
        }
        if carbohydrateGrams > 0, carbohydrateGrams.isFinite {
            events.append(.carbohydrate(CarbohydrateEvent(date: eventTime, grams: carbohydrateGrams)))
        }
        guard !events.isEmpty else {
            preview = nil
            return
        }
        let simulatedData = SimulationCalculator.applying(events: events, to: envelope.effectiveData)
        let scenarioSnapshot = DefaultActivityCalculator().snapshot(
            data: simulatedData,
            settings: envelope.run.settings,
            date: envelope.run.referenceDate
        )
        preview = SimulationScenario(
            caseID: record.id,
            baseComputationRunID: envelope.run.id,
            name: scenarioName.isEmpty ? "Simulation" : scenarioName,
            events: events,
            baseline: envelope.run.result.current,
            scenario: scenarioSnapshot
        )
    }

    private func saveScenario() {
        guard canSimulate, let preview,
              preview.baseComputationRunID == record.activeComputationRunID else { return }
        do {
            try library.storeSimulation(
                caseID: record.id,
                scenarioID: preview.id,
                basedOnComputationRunID: preview.baseComputationRunID,
                name: preview.name,
                createdAt: preview.createdAt,
                payload: preview
            )
            savedScenarios.append(preview)
            self.preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SimulationForecastChart: View {
    let envelope: StoredComputationEnvelope
    let scenario: SimulationScenario
    @State private var points: [Point] = []

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let insulin: Double
        let carbohydrates: Double
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Gesamt-IOB im Verlauf").font(.headline)
            Chart(points) { point in
                LineMark(x: .value("Zeit", point.date), y: .value("IE", point.insulin))
                    .foregroundStyle(by: .value("Verlauf", point.series))
            }
            .chartYAxisLabel("IE")
            .frame(height: 180)
            .accessibilityLabel("Vergleich des Gesamt-IOB von Basis und Simulation")
            Text("Aktive Kohlenhydrate im Verlauf").font(.headline)
            Chart(points) { point in
                LineMark(x: .value("Zeit", point.date), y: .value("Gramm", point.carbohydrates))
                    .foregroundStyle(by: .value("Verlauf", point.series))
            }
            .chartYAxisLabel("g")
            .frame(height: 180)
            .accessibilityLabel("Vergleich der aktiven Kohlenhydrate von Basis und Simulation")
        }
        .task(id: scenario.id) { calculate() }
    }

    private func calculate() {
        let calculator = DefaultActivityCalculator()
        let simulated = SimulationCalculator.applying(events: scenario.events, to: envelope.effectiveData)
        let result = calculator.calculate(
            data: simulated,
            settings: envelope.run.settings,
            referenceDate: envelope.run.referenceDate,
            forecastStepMinutes: 5
        )
        let baseline = [envelope.run.result.current] + envelope.run.result.forecast
        let forecast = [result.current] + result.forecast
        points = [("Basis", baseline), ("Simulation", forecast)].flatMap { name, snapshots in
            snapshots.compactMap { snapshot in
                guard let insulin = snapshot.totalIOB.value, let carbohydrates = snapshot.cob.value else {
                    return nil
                }
                return Point(date: snapshot.date, series: name, insulin: insulin, carbohydrates: carbohydrates)
            }
        }
    }
}

private struct SimulationComparisonRow: View {
    let title: String
    let baseline: Double?
    let scenario: Double?
    let delta: Double?
    let unit: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text(title)
                    .font(.headline)
                Text("Basis")
                Text("Szenario")
                Text("Delta")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GridRow {
                Text("")
                valueText(baseline)
                valueText(scenario)
                valueText(delta, signed: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ value: Double?, signed: Bool = false) -> Text {
        guard let value else { return Text("Nicht verfügbar") }
        let number = value.formatted(
            .number
                .sign(strategy: signed ? .always() : .automatic)
                .precision(.fractionLength(2))
        )
        return Text("\(number) \(unit)")
    }
}
