import InsulinOCRCore
import SwiftUI

struct SimulationView: View {
    @Environment(\.dismiss) private var dismiss
    let record: CaseEntity
    let library: CaseLibraryStore
    @Bindable var settings: AppSettings

    @State private var baseEnvelope: StoredComputationEnvelope?
    @State private var scenarioName = "Neue Simulation"
    /// Empty means a profile basal rate of 0 U/h.
    @State private var profileBasalText = ""
    @State private var drafts: [SimulationEventDraft] = []
    @State private var showBaseline = false
    @State private var visibleOrefCurves: Set<OrefCurveKind> = []
    @State private var showsSettings = false
    @State private var chartData: SimulationChartData?
    @State private var preview: SimulationScenario?
    @State private var savedScenarios: [SimulationScenario] = []
    @State private var errorMessage: String?

    private var canSimulate: Bool {
        record.status == .complete
            && baseEnvelope?.presentation.isComplete == true
            && baseEnvelope?.run.id == record.activeComputationRunID
    }

    private var profileBasal: Double {
        guard let typed = DailyProfileDraft.number(profileBasalText), typed.isFinite, (0...20).contains(typed) else {
            return 0
        }
        return typed
    }

    var body: some View {
        NavigationStack {
            Form {
                if canSimulate {
                    chartSection
                    inputSection
                    eventSection
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
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Simulations-Einstellungen", systemImage: "slider.horizontal.3") {
                        showsSettings = true
                    }
                    .accessibilityIdentifier("simulation.settings")
                    Button("Szenario speichern") { saveScenario() }
                        .disabled(!canSimulate || preview == nil)
                }
            }
            .task(id: record.activeComputationRunID) { load() }
            .onChange(of: record.status) { update() }
            .onChange(of: drafts) { update() }
            .onChange(of: profileBasalText) { update() }
            .onChange(of: scenarioName) { update() }
            .onChange(of: settings.simulation) { update() }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    SimulationSettingsView(settings: settings)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { showsSettings = false }
                            }
                        }
                }
            }
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

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        Section {
            Picker("Modell", selection: $settings.simulation.model) {
                Text("Loop").tag(GlucosePredictionModel.loop)
                Text("oref").tag(GlucosePredictionModel.oref)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("simulation.model")
            if let chartData {
                SimulationChart(
                    data: chartData,
                    limits: settings.simulation.limits,
                    unit: settings.glucoseUnit,
                    showBaseline: showBaseline,
                    visibleOrefCurves: visibleOrefCurves
                )
                if !chartData.orefCurves.isEmpty {
                    orefToggles(chartData)
                }
            }
            Toggle("Verlauf ohne Ereignisse einblenden", isOn: $showBaseline)
                .accessibilityIdentifier("simulation.baseline")
        } footer: {
            Text(chartFooter)
        }
    }

    private var chartFooter: String {
        let basal = DailyProfileDraft.text(profileBasal)
        let model = settings.simulation.model == .loop
            ? "Loop-Modell mit Momentum"
            : "oref-artige Kurven mit der KH-Aufnahmekurve dieser App, nicht bitgenau"
        return "Modellrechnung, keine Dosierungsempfehlung. \(model). Gerechnet mit Profil-Basalrate \(basal) IE/h; nach dem Aufnahmezeitpunkt gilt die Profil-Basalrate. Aktives Insulin enthält nur bereits abgegebenes Basal."
    }

    /// The oref curves beyond the main one, each switched on by its chip.
    private func orefToggles(_ data: SimulationChartData) -> some View {
        HStack(spacing: 8) {
            ForEach(data.orefCurves) { curve in
                let isOn = visibleOrefCurves.contains(curve.kind)
                Button {
                    if isOn {
                        visibleOrefCurves.remove(curve.kind)
                    } else {
                        visibleOrefCurves.insert(curve.kind)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Capsule().fill(SimulationChart.color(curve.kind)).frame(width: 12, height: 3)
                        Text(curve.kind.title)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(isOn ? Color.accentColor : Color.secondary)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    // MARK: - Inputs

    private var inputSection: some View {
        Section {
            TextField("Name", text: $scenarioName)
                .accessibilityIdentifier("simulation.name")
            LabeledContent("Profil-Basalrate") {
                TextField("IE/h", text: $profileBasalText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .accessibilityLabel("Profil-Basalrate in Einheiten pro Stunde")
                    .accessibilityIdentifier("simulation.profileBasal")
            }
        } header: {
            Text("Szenario")
        } footer: {
            Text("Die Profil-Basalrate ist der Bezugswert für abgegebenes Basal. Leer bedeutet 0 IE/h: Dann zählt das gesamte abgegebene Basal als glukosesenkend, und die Kurve fällt tiefer aus als mit deiner echten Basalrate.")
        }
    }

    private var eventSection: some View {
        Section {
            ForEach($drafts) { $draft in
                eventRow($draft)
            }
            .onDelete { drafts.remove(atOffsets: $0) }
            Menu {
                Button("Bolus", systemImage: "syringe.fill") {
                    drafts.append(SimulationEventDraft(kind: .bolus))
                }
                Button("Kohlenhydrate", systemImage: "fork.knife") {
                    drafts.append(SimulationEventDraft(kind: .carbohydrate))
                }
                ForEach(settings.simulation.activityPresets) { preset in
                    Button(preset.name, systemImage: "figure.run") {
                        drafts.append(SimulationEventDraft(preset: preset))
                    }
                }
                Button("Freie Aktivität", systemImage: "figure.walk") {
                    drafts.append(SimulationEventDraft(kind: .insulinNeed))
                }
            } label: {
                // The whole row opens the menu, not only the text.
                Label("Hinzufügen", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("simulation.addEvent")
        } header: {
            Text("Was-wäre-wenn-Ereignisse")
        } footer: {
            Text("Start in Minuten relativ zum Aufnahmezeitpunkt: 0 ist jetzt, 20 in zwanzig Minuten, -15 vor einer Viertelstunde. Simulationen bleiben getrennt von erkannten und korrigierten Therapiedaten.")
        }
    }

    private func eventRow(_ draft: Binding<SimulationEventDraft>) -> some View {
        let value = draft.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            Label(Self.title(value), systemImage: Self.symbol(value.kind))
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .bottom, spacing: 12) {
                eventField(Self.amountCaption(value.kind), text: draft.amountText, keyboard: .decimalPad,
                           identifier: "simulation.amount." + Self.identifier(value.kind))
                if value.kind == .insulinNeed {
                    eventField("Dauer (h)", text: draft.durationText, keyboard: .decimalPad,
                               identifier: "simulation.duration")
                }
                eventField("Start (min)", text: draft.offsetText, keyboard: .numbersAndPunctuation,
                           identifier: "simulation.offset." + Self.identifier(value.kind))
                if let date = value.date(reference: record.captureTime) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 7)
                }
            }
            if value.event(reference: record.captureTime) == nil {
                Text("Unvollständig oder ausserhalb des erlaubten Bereichs; wird nicht gerechnet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func eventField(
        _ caption: String, text: Binding<String>, keyboard: UIKeyboardType, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(caption, text: text)
                .keyboardType(keyboard)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .accessibilityIdentifier(identifier)
        }
    }

    private static func title(_ draft: SimulationEventDraft) -> String {
        switch draft.kind {
        case .bolus: "Bolus"
        case .carbohydrate: "Kohlenhydrate"
        case .insulinNeed: draft.title.map { "Aktivität: " + $0 } ?? "Freie Aktivität"
        }
    }

    private static func symbol(_ kind: SimulationEventDraft.Kind) -> String {
        switch kind {
        case .bolus: "syringe.fill"
        case .carbohydrate: "fork.knife"
        case .insulinNeed: "figure.run"
        }
    }

    private static func amountCaption(_ kind: SimulationEventDraft.Kind) -> String {
        switch kind {
        case .bolus: "Menge (IE)"
        case .carbohydrate: "Menge (g)"
        case .insulinNeed: "Bedarf (%)"
        }
    }

    private static func identifier(_ kind: SimulationEventDraft.Kind) -> String {
        switch kind {
        case .bolus: "bolus"
        case .carbohydrate: "carbohydrate"
        case .insulinNeed: "insulinNeed"
        }
    }

    // MARK: - Results

    private func resultSection(_ scenario: SimulationScenario) -> some View {
        Section {
            comparisonRows(scenario)
        } header: {
            Text("Basis, Szenario und Delta")
        } footer: {
            Text("Werte zum Aufnahmezeitpunkt. Ereignisse danach erscheinen in der Grafik, aber nicht in diesen Zahlen.")
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
                            SimulationChart(
                                data: chartData(for: scenario, envelope: envelope),
                                limits: settings.simulation.limits,
                                unit: settings.glucoseUnit,
                                showBaseline: false,
                                visibleOrefCurves: []
                            )
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

    // MARK: - Data

    private func load() {
        baseEnvelope = nil
        preview = nil
        chartData = nil
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
        update()
    }

    private func envelope(for scenario: SimulationScenario) -> StoredComputationEnvelope? {
        guard let entity = try? library.computationRuns(caseID: record.id).first(where: {
            $0.id == scenario.baseComputationRunID
        }) else { return nil }
        return try? JSONDecoder.insulinOCR.decode(StoredComputationEnvelope.self, from: entity.encodedPayload)
    }

    private func chartData(for scenario: SimulationScenario, envelope: StoredComputationEnvelope) -> SimulationChartData {
        SimulationChartBuilder.build(
            data: envelope.effectiveData,
            therapy: envelope.run.settings,
            reference: envelope.run.referenceDate,
            events: scenario.events,
            simulation: settings.simulation,
            profileBasalUnitsPerHour: scenario.profileBasalUnitsPerHour ?? 0,
            model: scenario.predictionModel ?? settings.simulation.model,
            timeZoneIdentifier: record.captureTimeZoneIdentifier
        )
    }

    /// Recomputes the chart and the scenario from the current inputs. The
    /// chart also shows the course without any simulated event.
    private func update() {
        guard canSimulate, let envelope = baseEnvelope else {
            preview = nil
            chartData = nil
            return
        }
        let events = drafts.compactMap { $0.event(reference: envelope.run.referenceDate) }
        chartData = SimulationChartBuilder.build(
            data: envelope.effectiveData,
            therapy: envelope.run.settings,
            reference: envelope.run.referenceDate,
            events: events,
            simulation: settings.simulation,
            profileBasalUnitsPerHour: profileBasal,
            model: settings.simulation.model,
            timeZoneIdentifier: record.captureTimeZoneIdentifier
        )
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
            scenario: scenarioSnapshot,
            profileBasalUnitsPerHour: profileBasal,
            predictionModel: settings.simulation.model
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
            drafts = []
            self.preview = nil
        } catch {
            errorMessage = error.localizedDescription
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
