import SwiftUI

struct OnboardingView: View {
    let appModel: AppModel
    @State private var diaMinutes: Int?
    @State private var insulinPreset: StoredInsulinPreset?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    onboardingHeader
                    safetyNotice
                    parameterForm
                    continueButton
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding()
            }
            .navigationTitle("InsulinOCR")
        }
    }

    private var onboardingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Therapieverlauf aus einem Screenshot")
                .font(.title.bold())
            Text("InsulinOCR verarbeitet CamAPS-FX-Querformat-Screenshots lokal und erstellt daraus einen unveränderlichen Case.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text("Experimentelle Schätzung")
                    .font(.headline)
                Text("Die App ist kein Medizinprodukt und gibt keine Dosierungsempfehlungen. Unsichere kritische Werte werden nicht berechnet.")
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        }
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var parameterForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Für die erste Berechnung erforderlich")
                .font(.headline)

            Text("Insulinwirkdauer (DIA)")
                .font(.headline)
                .accessibilityIdentifier("onboarding.dia.label")
            Text("DIA bedeutet „Duration of Insulin Action“. Die gewählte Zeit legt fest, wie lange eine Insulinabgabe im Rechenmodell nachwirkt. Die Zahlen im Auswahlmenü sind Stunden.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Insulinwirkdauer in Stunden", selection: $diaMinutes) {
                Text("Bitte wählen").tag(Int?.none)
                ForEach(Array(stride(from: 180, through: 600, by: 30)), id: \.self) { minutes in
                    Text(Self.durationLabel(minutes)).tag(Int?.some(minutes))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("onboarding.dia")

            Text("Verwendetes Insulin")
                .font(.headline)
            Text("Wähle dein Insulin. Der angezeigte Peak ist der Zeitpunkt der stärksten Wirkung im Modell, in Minuten nach der Abgabe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Insulintyp", selection: $insulinPreset) {
                Text("Bitte wählen").tag(StoredInsulinPreset?.none)
                ForEach(StoredInsulinPreset.allCases) { preset in
                    Text("\(preset.localizedName), Peak \(preset.peakMinutes) min")
                        .tag(StoredInsulinPreset?.some(preset))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("onboarding.insulin")

            Text("Kohlenhydrate werden zunächst mit vier Stunden Absorptionsdauer und zehn Minuten Verzögerung modelliert. Dies lässt sich in den Einstellungen ändern. Für eine vollständige Berechnung muss der Screenshot mindestens die längere dieser beiden Zeiten abdecken: DIA oder KH-Absorptionsdauer plus zehn Minuten.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var continueButton: some View {
        Button("Einrichtung abschließen", systemImage: "arrow.right.circle.fill") {
            guard let diaMinutes, let insulinPreset else { return }
            appModel.onboardingCompleted(diaMinutes: diaMinutes, insulinPreset: insulinPreset)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(diaMinutes == nil || insulinPreset == nil)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private static func durationLabel(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60
        return hours.formatted(.number.precision(.fractionLength(minutes.isMultiple(of: 60) ? 0 : 1))) + " h"
    }
}
