import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: AppModel
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                therapySection
                unitSection
                cloudSection
                privacySection
                aboutSection
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onChange(of: settings.iCloudEnabled) {
                Task { await appModel.applyCloudPreference() }
            }
        }
    }

    private var therapySection: some View {
        Section {
            Picker("Insulinwirkdauer (DIA)", selection: $settings.diaMinutes) {
                ForEach(Array(stride(from: 180, through: 600, by: 30)), id: \.self) { minutes in
                    Text(durationLabel(minutes)).tag(minutes)
                }
            }
            Picker("Insulintyp", selection: $settings.insulinPreset) {
                ForEach(StoredInsulinPreset.allCases) { preset in
                    Text("\(preset.localizedName), Peak \(preset.peakMinutes) min").tag(preset)
                }
            }
            Picker("KH-Absorptionsdauer", selection: $settings.carbAbsorptionMinutes) {
                ForEach(Array(stride(from: 120, through: 480, by: 30)), id: \.self) { minutes in
                    Text(durationLabel(minutes)).tag(minutes)
                }
            }
        } header: {
            Text("Wirkmodelle")
        } footer: {
            Text("DIA ist die gesamte Insulinwirkdauer im Modell, angegeben in Stunden. Der Peak bezeichnet die stärkste Modellwirkung in Minuten nach der Abgabe. Die KH-Absorptionsdauer bestimmt den Abbau der Kohlenhydrate nach zehn Minuten Verzögerung. Änderungen überschreiben keine historischen Ergebnisse. Eine explizite Neuberechnung erzeugt einen neuen Rechenlauf.")
        }
    }

    private var unitSection: some View {
        Section("Anzeige") {
            Picker("Glukoseeinheit", selection: $settings.glucoseUnit) {
                ForEach(GlucoseDisplayUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var cloudSection: some View {
        Section {
            Toggle("Vollständige iCloud-Synchronisierung", isOn: $settings.iCloudEnabled)
        } header: {
            Text("iCloud")
        } footer: {
            Text("Standardmäßig aus. Nach Aktivierung werden vollständige Cases in deine private CloudKit-Datenbank gespiegelt. Lokale Daten bleiben bei einem Ausfall erhalten.")
        }
    }

    private var privacySection: some View {
        Section("Datenschutz") {
            Label("Lokale Bildanalyse", systemImage: "iphone.and.arrow.forward")
            Label("Kein Tracking und keine Analytics", systemImage: "hand.raised.fill")
            Label("Dateischutz für Screenshots", systemImage: "lock.doc.fill")
        }
    }

    private var aboutSection: some View {
        Section("Über diese App") {
            NavigationLink("Sicherheitshinweise") {
                SafetyInformationView()
            }
            NavigationLink("Lizenzen") {
                LicenseInformationView()
            }
            LabeledContent("App-Version", value: appVersion)
            LabeledContent("Export-Schema", value: "CaseArchive v1")
            LabeledContent("Modell", value: "OpenAPS exponential / LoopKit COB")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }

    private func durationLabel(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60
        return hours.formatted(.number.precision(.fractionLength(minutes.isMultiple(of: 60) ? 0 : 1))) + " h"
    }
}

private struct SafetyInformationView: View {
    var body: some View {
        List {
            Section("Experimenteller Zweck") {
                Text("InsulinOCR dient der persönlichen Verlaufsdarstellung und Qualitätsprüfung. Die Ergebnisse sind Schätzungen aus einem Screenshot.")
                Text("Die App ist kein Medizinprodukt und gibt keine Dosierungs- oder Therapieempfehlungen.")
            }
            Section("Fail-closed") {
                Text("Unsichere kritische Insulin- oder Kohlenhydratmengen führen zu „unvollständig“. Die App zeigt dann keinen still geschätzten IOB-/COB-Wert.")
            }
            Section("Im Zweifel") {
                Text("Verlasse dich für Therapieentscheidungen auf die freigegebenen Anzeigen deiner Therapiegeräte und die Empfehlung deines Behandlungsteams.")
            }
        }
        .navigationTitle("Sicherheit")
    }
}

private struct LicenseInformationView: View {
    var body: some View {
        List {
            Section("Open-Source-Grundlagen") {
                Text("Die Wirkmodelle sind eine eigenständige Neuimplementierung auf Grundlage der MIT-lizenzierten Projekte OpenAPS oref0 und LoopKit.")
                Text("ZIPFoundation 0.9.20 wird unter der MIT-Lizenz verwendet.")
            }
            Section("Abgrenzung") {
                Text("Es wurde kein GPL-Code aus xdripswift übernommen. CamAPS ist eine kompatible Screenshotquelle; InsulinOCR ist weder verbunden noch autorisiert und übernimmt keine Logos oder proprietären Assets.")
            }
        }
        .navigationTitle("Lizenzen")
    }
}
