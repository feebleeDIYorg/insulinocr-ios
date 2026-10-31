import InsulinOCRCore
import SwiftUI

struct CaseDetailView: View {
    @Bindable var appModel: AppModel
    @Bindable var library: CaseLibraryStore
    let record: CaseEntity

    @State private var canCorrectAnalysis = false
    @State private var presentation: StoredCasePresentation?
    @State private var presentedSheet: PresentedSheet?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                caseHeader
                metrics
                analysisContent
                provenanceFooter
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding()
        }
        .navigationTitle(record.title)
        .toolbar { detailToolbar }
        .task(id: record.activeComputationRunID) { loadPresentation() }
        .task(id: record.activeAnalysisRunID) { loadAnalysisAvailability() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .captureTime:
                CaptureTimeEditor(record: record, library: library, appModel: appModel)
            case .correction:
                CorrectionEditorView(record: record, library: library, appModel: appModel)
            case .simulation:
                SimulationView(record: record, library: library)
            case .settings:
                SettingsView(appModel: appModel, settings: appModel.settings)
            }
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert(
            "Export fehlgeschlagen",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var caseHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aufnahmezeitpunkt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.captureTime, format: .dateTime.day().month().year().hour().minute())
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                Spacer()
                StatusBadge(status: record.status)
            }
            Text(captureTimeExplanation)
                .font(.footnote)
                .foregroundStyle(record.captureTimeSource == .importTime ? Color.orange : Color.secondary)
                .accessibilityIdentifier("case.captureTimeSource")
            Button("Aufnahmezeit prüfen", systemImage: "calendar.badge.clock") {
                presentedSheet = .captureTime
            }
            .disabled(record.status == .analyzing)
            .accessibilityIdentifier("case.captureTimeReview")
            if let reason = record.reviewReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text("Der Case ist gespeichert, aber IOB und aktive Kohlenhydrate bleiben gesperrt. Prüfe zuerst den Aufnahmezeitpunkt und die Zeitbeschriftungen. Bei fehlenden Basalabschnitten braucht die App einen vollständig sichtbaren Verlauf; eine nicht erkannte Menge lässt sich in „Korrigieren“ prüfen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Der Case bleibt auf diesen Zeitpunkt eingefroren. Späteres Öffnen verändert IOB und COB nicht.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var captureTimeExplanation: String {
        switch record.captureTimeSource {
        case .imageMetadata: "Zeitquelle: Bildmetadaten. Bitte bei abweichenden Zeitbeschriftungen prüfen."
        case .fileMetadata: "Zeitquelle: Dateimetadaten. Diese Zeit kann vom tatsächlichen Screenshot-Zeitpunkt abweichen."
        case .importTime: "Aufnahmezeit unbekannt: Es wird die Importzeit verwendet. Bitte den tatsächlichen Screenshot-Zeitpunkt prüfen."
        case .userCorrection: "Zeitquelle: von dir bestätigter Aufnahmezeitpunkt."
        }
    }

    private var metrics: some View {
        let reason = presentation?.unavailableReasons.first
            ?? (record.status == .complete ? nil : "Kritische Daten sind noch nicht vollständig bestätigt.")
        let values = presentation?.isComplete == true && record.status == .complete
            ? presentation?.metrics
            : nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricCard(title: "Basal IOB", value: values?.basalIOB, unit: "IE", tint: .blue, unavailableReason: values?.basalIOB == nil ? reason : nil)
            MetricCard(title: "Bolus IOB", value: values?.bolusIOB, unit: "IE", tint: .indigo, unavailableReason: values?.bolusIOB == nil ? reason : nil)
            MetricCard(title: "Gesamt IOB", value: values?.totalIOB, unit: "IE", tint: .purple, unavailableReason: values?.totalIOB == nil ? reason : nil)
            MetricCard(title: "Aktive KH", value: values?.activeCarbohydrates, unit: "g", tint: .orange, unavailableReason: values?.activeCarbohydrates == nil ? reason : nil)
        }
    }

    @ViewBuilder
    private var analysisContent: some View {
        if let presentation {
            TherapyCharts(
                presentation: presentation,
                activityIsAvailable: presentation.isComplete && record.status == .complete,
                glucoseUnit: appModel.settings.glucoseUnit
            )
        } else {
            ContentUnavailableView {
                Label("Noch kein vollständiger Rechenlauf", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text("Die Analyse läuft lokal. Bei unsicheren kritischen Werten bleibt das numerische Resultat gesperrt.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var provenanceFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Case-ID \(record.id.uuidString)")
            Text("Referenzzeit \((presentation?.referenceTime ?? record.captureTime).ISO8601Format())")
            Text("Experimentelle Schätzung – keine Dosierungsempfehlung")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Aufnahmezeit bearbeiten", systemImage: "calendar.badge.clock") {
                presentedSheet = .captureTime
            }
            .disabled(record.status == .analyzing)
            Button("Korrigieren", systemImage: "scope") {
                presentedSheet = .correction
            }
            .disabled(!canCorrectAnalysis || record.status == .analyzing)
            Button("Simulation", systemImage: "function") {
                presentedSheet = .simulation
            }
            .disabled(presentation?.isComplete != true || record.status != .complete)
            Menu("Weitere Aktionen", systemImage: "ellipsis.circle") {
                Button("Screenshot erneut analysieren", systemImage: "viewfinder") {
                    Task { await appModel.reanalyzeCase(caseID: record.id) }
                }
                .disabled(record.status == .analyzing)
                Button("Mit aktuellen Parametern neu berechnen", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await appModel.recomputeCase(caseID: record.id) }
                }
                .disabled(!canCorrectAnalysis || record.status == .analyzing)
                Button("QA-Archiv exportieren", systemImage: "archivebox") {
                    Task { await exportCase() }
                }
                Button("Berechnungsparameter", systemImage: "slider.horizontal.3") {
                    presentedSheet = .settings
                }
            }
            .accessibilityIdentifier("case.actions")
        }
    }

    private func loadAnalysisAvailability() {
        canCorrectAnalysis = false
        guard let id = record.activeAnalysisRunID,
              let entity = try? library.analysisRuns(caseID: record.id).first(where: { $0.id == id }) else { return }
        canCorrectAnalysis = (try? JSONDecoder.insulinOCR.decode(StoredAnalysisEnvelope.self,
                                                              from: entity.encodedPayload)) != nil
            || (try? JSONDecoder.insulinOCR.decode(InsulinOCRCore.AnalysisRun.self,
                                                  from: entity.encodedPayload)) != nil
    }

    private func loadPresentation() {
        guard let runID = record.activeComputationRunID,
              let entity = try? library.computationRuns(caseID: record.id).first(where: { $0.id == runID }) else {
            presentation = nil
            return
        }
        presentation = try? JSONDecoder.insulinOCR
            .decode(StoredComputationEnvelope.self, from: entity.encodedPayload)
            .presentation
    }

    private func exportCase() async {
        do {
            let snapshot = try await CaseArchiveSnapshot.make(caseID: record.id, library: library, fileStore: appModel.fileStore)
            exportURL = try await CaseArchiveExporter().export(snapshot)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private enum PresentedSheet: String, Identifiable {
    case captureTime
    case correction
    case simulation
    case settings

    var id: String { rawValue }
}

private struct CaptureTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let record: CaseEntity
    let library: CaseLibraryStore
    let appModel: AppModel
    @State private var captureTime: Date
    @State private var errorMessage: String?

    init(record: CaseEntity, library: CaseLibraryStore, appModel: AppModel) {
        self.record = record
        self.library = library
        self.appModel = appModel
        self.captureTime = record.captureTime
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Aufnahmezeitpunkt", selection: $captureTime)
                Text("Beim Speichern wird das Originalbild mit diesem Zeitpunkt erneut analysiert. Bei auswertbaren Daten entsteht ein neuer Rechenlauf. Frühere Läufe bleiben erhalten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Aufnahmezeit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task {
                            do {
                                try library.updateCaptureTime(caseID: record.id, captureTime: captureTime)
                                await appModel.reanalyzeCase(caseID: record.id)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(record.status == .analyzing)
                }
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
