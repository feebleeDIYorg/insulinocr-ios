import InsulinOCRCore
import SwiftUI

/// Settings of the glucose prediction: daily profiles, activity presets and
/// glucose limits. Pushed from the settings and opened from the simulation.
struct SimulationSettingsView: View {
    @Bindable var settings: AppSettings

    @State private var hypoText = ""
    @State private var targetLowText = ""
    @State private var targetHighText = ""
    @State private var hyperText = ""
    @State private var presetEditing: PresetEditing?

    private var glucoseScale: Double { settings.glucoseUnit == .mgdL ? 18 : 1 }

    var body: some View {
        Form {
            profileSection
            presetSection
            limitsSection
            Section {
                Text("Die Vorhersage ist eine Modellrechnung mit deinen Werten. Sie ist experimentell und keine Dosierungsempfehlung.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Simulation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadLimits() }
        .onChange(of: settings.glucoseUnit) { loadLimits() }
        .onChange(of: [hypoText, targetLowText, targetHighText, hyperText]) { applyLimits() }
        .sheet(item: $presetEditing) { editing in
            ActivityPresetEditor(existing: editing.preset) { saved in
                if let index = settings.simulation.activityPresets.firstIndex(where: { $0.id == saved.id }) {
                    settings.simulation.activityPresets[index] = saved
                } else {
                    settings.simulation.activityPresets.append(saved)
                }
            }
        }
    }

    private var profileSection: some View {
        Section {
            NavigationLink {
                DailyProfileEditor(
                    title: "Insulinsensitivität",
                    unitLabel: "\(settings.glucoseUnit.label) je IE",
                    displayScale: glucoseScale,
                    allowed: SimulationSettings.sensitivityRange,
                    profile: $settings.simulation.sensitivity
                )
            } label: {
                LabeledContent("Insulinsensitivität (ISF)",
                    value: summary(settings.simulation.sensitivity, scale: glucoseScale,
                                   unit: "\(settings.glucoseUnit.label) je IE"))
            }
            .accessibilityIdentifier("simulationSettings.sensitivity")
            NavigationLink {
                DailyProfileEditor(
                    title: "KH-Faktor",
                    unitLabel: "g je IE",
                    displayScale: 1,
                    allowed: SimulationSettings.carbRatioRange,
                    profile: $settings.simulation.carbRatio
                )
            } label: {
                LabeledContent("KH-Faktor",
                    value: summary(settings.simulation.carbRatio, scale: 1, unit: "g je IE"))
            }
            .accessibilityIdentifier("simulationSettings.carbRatio")
        } header: {
            Text("Tagesprofile")
        } footer: {
            Text("Die Insulinsensitivität gibt an, um wie viel eine Einheit Insulin die Glukose senkt. Der KH-Faktor gibt an, wie viele Gramm Kohlenhydrate eine Einheit abdeckt. Ohne beide Profile zeigt die Simulation keinen Glukoseverlauf.")
        }
    }

    private var presetSection: some View {
        Section {
            ForEach(settings.simulation.activityPresets) { preset in
                Button {
                    presetEditing = PresetEditing(preset: preset)
                } label: {
                    LabeledContent(preset.name, value: Self.presetSummary(preset))
                }
                .foregroundStyle(.primary)
            }
            .onDelete { settings.simulation.activityPresets.remove(atOffsets: $0) }
            Button("Vorlage hinzufügen", systemImage: "plus") {
                presetEditing = PresetEditing(preset: nil)
            }
            .accessibilityIdentifier("simulationSettings.addPreset")
        } header: {
            Text("Aktivitäts-Vorlagen")
        } footer: {
            Text("Eine Vorlage ändert den Insulinbedarf für eine Dauer: 100 % ist normal, 70 % bedeutet weniger Insulinbedarf. Basal-Bezug, Insulinsensitivität und KH-Faktor werden gemeinsam angepasst, wie bei Overrides in Loop oder Profil-Prozenten in AndroidAPS.")
        }
    }

    private var limitsSection: some View {
        Section {
            limitField("Hypo-Grenze", text: $hypoText)
            limitField("Zielbereich von", text: $targetLowText)
            limitField("Zielbereich bis", text: $targetHighText)
            limitField("Hyper-Grenze", text: $hyperText)
            if typedLimits?.isValid != true {
                Text("Nicht gespeichert. Die Werte müssen aufsteigend sein: Hypo-Grenze ≤ Zielbereich von < Zielbereich bis ≤ Hyper-Grenze.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Glukosegrenzen in \(settings.glucoseUnit.label)")
        } footer: {
            Text("Der Zielbereich erscheint als Band in der Grafik. Vorhergesagte Werte unter der Hypo-Grenze werden rot, über der Hyper-Grenze gelb gezeichnet.")
        }
    }

    private func limitField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(settings.glucoseUnit.label, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .accessibilityLabel(title)
        }
    }

    private var typedLimits: GlucoseLimits? {
        let values = [hypoText, targetLowText, targetHighText, hyperText].map(DailyProfileDraft.number)
        guard let hypo = values[0], let low = values[1], let high = values[2], let hyper = values[3] else {
            return nil
        }
        return GlucoseLimits(hypo: hypo / glucoseScale, targetLow: low / glucoseScale,
                             targetHigh: high / glucoseScale, hyper: hyper / glucoseScale)
    }

    /// Only a complete, ordered set of limits replaces the stored one.
    private func applyLimits() {
        if let limits = typedLimits, limits.isValid, limits != settings.simulation.limits {
            settings.simulation.limits = limits
        }
    }

    private func loadLimits() {
        let limits = settings.simulation.limits
        let format = settings.glucoseUnit == .mgdL ? "%.0f" : "%.1f"
        hypoText = String(format: format, limits.hypo * glucoseScale)
        targetLowText = String(format: format, limits.targetLow * glucoseScale)
        targetHighText = String(format: format, limits.targetHigh * glucoseScale)
        hyperText = String(format: format, limits.hyper * glucoseScale)
    }

    private func summary(_ profile: DailyProfile?, scale: Double, unit: String) -> String {
        guard let profile else { return "Nicht festgelegt" }
        if profile.blocks.count == 1 {
            return "\(DailyProfileDraft.text(profile.blocks[0].value * scale)) \(unit)"
        }
        return "\(profile.blocks.count) Zeitblöcke"
    }

    static func presetSummary(_ preset: ActivityPreset) -> String {
        let hours = Double(preset.durationMinutes) / 60
        return "\(DailyProfileDraft.text(preset.insulinNeedPercent)) % · \(DailyProfileDraft.text(hours)) h"
    }
}

private struct PresetEditing: Identifiable {
    let id = UUID()
    let preset: ActivityPreset?
}

/// Time blocks of one daily profile: start time and value per row.
private struct DailyProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let unitLabel: String
    let displayScale: Double
    let allowed: ClosedRange<Double>
    @Binding var profile: DailyProfile?

    @State private var draft = DailyProfileDraft(rows: [])
    @State private var isLoaded = false

    private var typedProfile: DailyProfile? {
        draft.profile(displayScale: displayScale, allowed: allowed)
    }

    var body: some View {
        Form {
            Section {
                ForEach($draft.rows) { $row in
                    HStack {
                        if row.id == draft.rows.first?.id {
                            Text("ab 00:00").monospacedDigit()
                        } else {
                            DatePicker("Beginn", selection: time($row.startMinute),
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        Spacer()
                        TextField(unitLabel, text: $row.text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 130)
                            .accessibilityLabel("Wert in \(unitLabel)")
                    }
                    .deleteDisabled(row.id == draft.rows.first?.id)
                }
                .onDelete { draft.rows.remove(atOffsets: $0) }
                Button("Zeitblock hinzufügen", systemImage: "plus") { draft.addRow() }
                    .disabled(!draft.canAddRow)
            } header: {
                Text("Zeitblöcke in \(unitLabel)")
            } footer: {
                Text("Jeder Block gilt ab seiner Startzeit bis zum nächsten Block. Der erste beginnt immer um 00:00. Sichern ist möglich, sobald jeder Block einen Wert zwischen \(DailyProfileDraft.text(allowed.lowerBound * displayScale)) und \(DailyProfileDraft.text(allowed.upperBound * displayScale)) hat und keine zwei Blöcke gleichzeitig beginnen.")
            }
            if profile != nil {
                Section {
                    Button("Profil entfernen", role: .destructive) {
                        profile = nil
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    if let typedProfile {
                        profile = typedProfile
                        dismiss()
                    }
                }
                .disabled(typedProfile == nil)
            }
        }
        .onAppear {
            if !isLoaded {
                draft = DailyProfileDraft(profile: profile, displayScale: displayScale)
                isLoaded = true
            }
        }
    }

    /// Minute of the day as a time for the picker; the date part is irrelevant.
    private func time(_ minute: Binding<Int>) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return Binding(
            get: { calendar.date(byAdding: .minute, value: minute.wrappedValue, to: midnight) ?? midnight },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

private struct ActivityPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: ActivityPreset?
    let save: (ActivityPreset) -> Void

    @State private var name = ""
    @State private var percentText = ""
    @State private var hoursText = ""
    @State private var isLoaded = false

    private var typedPreset: ActivityPreset? {
        guard let percent = DailyProfileDraft.number(percentText),
              let hours = DailyProfileDraft.number(hoursText), hours.isFinite, hours > 0, hours <= 48 else {
            return nil
        }
        let preset = ActivityPreset(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            insulinNeedPercent: percent,
            durationMinutes: Int((hours * 60).rounded())
        )
        return preset.isValid ? preset : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    LabeledContent("Insulinbedarf") {
                        TextField("%", text: $percentText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityLabel("Insulinbedarf in Prozent")
                    }
                    LabeledContent("Dauer") {
                        TextField("h", text: $hoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityLabel("Dauer in Stunden")
                    }
                } footer: {
                    Text("Insulinbedarf zwischen 10 und 300 %: 100 % ist normal, darunter brauchst du weniger Insulin. Dauer zwischen 0.25 und 48 Stunden.")
                }
            }
            .navigationTitle(existing == nil ? "Neue Vorlage" : "Vorlage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let typedPreset {
                            save(typedPreset)
                            dismiss()
                        }
                    }
                    .disabled(typedPreset == nil)
                }
            }
            .onAppear {
                if !isLoaded, let existing {
                    name = existing.name
                    percentText = DailyProfileDraft.text(existing.insulinNeedPercent)
                    hoursText = DailyProfileDraft.text(Double(existing.durationMinutes) / 60)
                }
                isLoaded = true
            }
        }
    }
}
