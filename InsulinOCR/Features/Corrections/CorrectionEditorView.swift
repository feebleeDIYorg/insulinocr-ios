import InsulinOCRCore
import SwiftUI
import UIKit

struct CorrectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let record: CaseEntity
    let library: CaseLibraryStore
    let appModel: AppModel

    @State private var analysisRun: AnalysisRun?
    @State private var drafts: [ObservationDraft] = []
    @State private var selectedObservationID: UUID?
    @State private var filter: ReviewFilter = .unconfirmed
    @State private var visibleLimit = 20
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let analysisRun {
                    editor(analysisRun: analysisRun)
                } else {
                    ProgressView("Analyse wird geladen …")
                }
            }
            .navigationTitle("Erkennung prüfen")
            .toolbar { editorToolbar }
            .task { load() }
            .alert(
                "Korrektur nicht gespeichert",
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

    private func editor(analysisRun: AnalysisRun) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ScreenshotObservationOverlay(
                    caseID: record.id,
                    library: library,
                    observations: analysisRun.observations,
                    selectedObservationID: $selectedObservationID
                )
                .frame(maxWidth: .infinity)

                Label(
                    "Rohbeobachtungen bleiben unverändert. Speichern erzeugt eine neue Korrekturrevision und einen neuen Rechenlauf.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                LabeledContent("Datenpunkte filtern") {
                    Picker("Datenpunkte filtern", selection: $filter) {
                        ForEach(ReviewFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("correction.filter")
                }
                Text("\(filteredDrafts.count) von \(drafts.count) Datenpunkten. Zum Bearbeiten einen Eintrag öffnen. Alle Werte bleiben im QA-Export enthalten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                basalGapReview(analysisRun: analysisRun)

                if let selected = drafts.first(where: { $0.id == selectedObservationID }) {
                    Text("Ausgewählter Datenpunkt").font(.headline)
                    ObservationDraftCard(draft: binding(for: selected), isSelected: true) {}
                        .accessibilityIdentifier("correction.selected")
                }
                if filteredDrafts.isEmpty {
                    Text("Keine Datenpunkte in diesem Filter. Andere Typen lassen sich über das Filtermenü auswählen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredDrafts.prefix(visibleLimit)) { draft in
                    Button {
                        selectedObservationID = draft.id
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.kindTitle).font(.subheadline.weight(.semibold))
                                Text(draft.startDate, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(draft.amountText.isEmpty ? "Menge unbekannt" : draft.amountText)
                                .monospacedDigit()
                            Image(systemName: "pencil")
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                    .accessibilityIdentifier("correction.observation")
                }
                if filteredDrafts.count > visibleLimit {
                    Button("Weitere 20 Datenpunkte anzeigen") { visibleLimit += 20 }
                }

                Menu("Beobachtung hinzufügen", systemImage: "plus") {
                    Button("Basalrate") { addDraft(kind: .basalRate) }
                    Button("Glukose") { addDraft(kind: .glucose) }
                    Button("Bolus") { addDraft(kind: .bolus) }
                    Button("Kohlenhydrate") { addDraft(kind: .carbohydrate) }
                }
                .buttonStyle(.bordered)

                TextField("Notiz zur Korrektur", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding()
        }
        .onChange(of: filter) { visibleLimit = 20 }
    }

    @ViewBuilder
    private func basalGapReview(analysisRun: AnalysisRun) -> some View {
        if !analysisRun.quality.blockers.contains(.invalidTimeAxis),
           !analysisRun.quality.blockers.contains(.invalidBasalAxis) {
            let start = max(analysisRun.calibration.timeStart,
                            record.captureTime.addingTimeInterval(-Double(appModel.settings.diaMinutes) * 60))
            if start < record.captureTime {
                let intervals = drafts.compactMap { draft -> DateInterval? in
                    guard !draft.isDeleted, draft.kind == .basalRate,
                          let end = draft.endDate, end > draft.startDate else { return nil }
                    return DateInterval(start: draft.startDate, end: end)
                }
                let gaps = BasalGapReview.gaps(intervals: intervals,
                    in: DateInterval(start: start, end: record.captureTime))
                if !gaps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Lücken der Basalhistorie").font(.headline)
                        Text("Prüfe diese Zeiträume und trage eine dir bekannte Basalrate ein. Die Grenzen werden sekundengenau übernommen; die Rate bleibt zur Eingabe leer.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(gaps.prefix(3).enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Von: \(item.element.start.formatted(.dateTime.day().month().hour().minute().second()))")
                                Text("Bis: \(item.element.end.formatted(.dateTime.day().month().hour().minute().second()))")
                                Button("Basalintervall prüfen") { addBasalGap(item.element) }
                                    .accessibilityIdentifier("correction.reviewBasalGap")
                                    .disabled(isSaving)
                            }
                            .font(.footnote.monospacedDigit())
                        }
                        if gaps.count > 3 {
                            Text("Weitere Zeitlücken werden nach diesen Einträgen angezeigt.").font(.footnote)
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: .rect(cornerRadius: 14))
                }
            }
        }
    }

    private func addBasalGap(_ gap: DateInterval) {
        var draft = ObservationDraft(newKind: .basalRate, date: gap.end)
        draft.startDate = gap.start
        draft.endDate = gap.end
        drafts.append(draft)
        selectedObservationID = draft.id
        filter = .basal
    }

    private var filteredDrafts: [ObservationDraft] {
        drafts.filter { filter.includes($0) }
    }

    private func binding(for draft: ObservationDraft) -> Binding<ObservationDraft> {
        Binding(
            get: { drafts.first(where: { $0.id == draft.id }) ?? draft },
            set: { replacement in
                if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
                    drafts[index] = replacement
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Abbrechen") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Revision speichern") {
                Task { await save() }
            }
            .disabled(isSaving || operations.isEmpty)
        }
    }

    private var operations: [CorrectionOperation] {
        drafts.compactMap(\.operation)
    }

    private func load() {
        guard let analysisID = record.activeAnalysisRunID,
              let entity = try? library.analysisRuns(caseID: record.id).first(where: { $0.id == analysisID }) else {
            errorMessage = "Kein aktiver Analyselauf vorhanden."
            return
        }
        let run: AnalysisRun?
        if let envelope = try? JSONDecoder.insulinOCR.decode(StoredAnalysisEnvelope.self, from: entity.encodedPayload) {
            run = envelope.run
        } else {
            run = try? JSONDecoder.insulinOCR.decode(AnalysisRun.self, from: entity.encodedPayload)
        }
        guard let run else {
            errorMessage = "Der Analyselauf konnte nicht gelesen werden."
            return
        }
        analysisRun = run
        do {
            let stored = try library.correctionRevisions(caseID: record.id)
                .filter { $0.basedOnAnalysisRunID == run.id }
            guard stored.allSatisfy({ !$0.hasConflict }) else {
                errorMessage = "Konkurrierende Korrekturen müssen vor weiteren Änderungen aufgelöst werden."
                return
            }
            let decoded: [CorrectionRevision] = try stored.map {
                try JSONDecoder.insulinOCR.decode(CorrectionRevision.self, from: $0.encodedPayload)
            }
            let revisions = decoded.sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
            var observations = Dictionary(uniqueKeysWithValues: run.observations.map { ($0.id, $0) })
            for revision in revisions {
                for operation in revision.operations {
                    switch operation {
                    case .add(let observation): observations[observation.id] = observation
                    case .update(let id, let replacement): observations[id] = replacement
                    case .delete(let id): observations[id] = nil
                    }
                }
            }
            drafts = observations.values.sorted {
                $0.startDate == $1.startDate
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.startDate < $1.startDate
            }.map(ObservationDraft.init)
            filter = drafts.contains(where: { $0.amountText.isEmpty }) ? .unconfirmed : .basal
            selectedObservationID = filteredDrafts.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addDraft(kind: ObservationKind) {
        let draft = ObservationDraft(newKind: kind, date: record.captureTime)
        drafts.append(draft)
        selectedObservationID = draft.id
    }

    private func save() async {
        guard let analysisRun else { return }
        isSaving = true
        defer { isSaving = false }
        let revision = CorrectionRevision(
            caseID: record.id,
            analysisRunID: analysisRun.id,
            parentRevisionID: record.activeCorrectionRevisionID,
            operations: operations,
            note: note.isEmpty ? nil : note
        )
        do {
            try await appModel.applyCorrection(revision)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum ReviewFilter: String, CaseIterable, Identifiable {
    case unconfirmed, events, basal, glucose, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unconfirmed: "Unbestätigte Mengen"
        case .events: "Bolus und Kohlenhydrate"
        case .basal: "Basalraten"
        case .glucose: "Glukose"
        case .all: "Alle Datenpunkte"
        }
    }
    func includes(_ draft: ObservationDraft) -> Bool {
        switch self {
        case .unconfirmed: draft.amountText.isEmpty
        case .events: [.bolus, .carbohydrate, .eventStem].contains(draft.kind)
        case .basal: draft.kind == .basalRate
        case .glucose: draft.kind == .glucose
        case .all: true
        }
    }
}

private struct ObservationDraft: Identifiable, Equatable {
    let id: UUID
    let original: RawObservation?
    var kind: ObservationKind
    var startDate: Date
    var endDate: Date?
    var amountText: String
    var isDeleted: Bool

    init(_ observation: RawObservation) {
        id = observation.id
        original = observation
        kind = observation.kind
        startDate = observation.startDate
        endDate = observation.endDate
        amountText = observation.amount.map { String(format: "%.12g", $0) } ?? ""
        isDeleted = false
    }

    init(newKind: ObservationKind, date: Date) {
        id = UUID()
        original = nil
        kind = newKind
        startDate = newKind == .basalRate ? date.addingTimeInterval(-300) : date
        endDate = newKind == .basalRate ? date : nil
        amountText = ""
        isDeleted = false
    }

    var kindTitle: String {
        switch kind {
        case .basalRate: "Basalrate (IE/h)"
        case .glucose: "Glukose (mmol/l)"
        case .bolus: "Bolus (IE)"
        case .carbohydrate: "Kohlenhydrate (g)"
        case .eventStem: "Unklassifiziertes Ereignis"
        }
    }

    var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    var operation: CorrectionOperation? {
        if isDeleted {
            return original == nil ? nil : .delete(targetID: id)
        }
        let replacement = makeObservation()
        guard let original else { return .add(replacement) }
        let unchanged = kind == original.kind
            && startDate == original.startDate
            && (kind == .basalRate ? endDate : nil) == original.endDate
            && amountText == (original.amount.map { String(format: "%.12g", $0) } ?? "")
        return unchanged ? nil : .update(targetID: id, replacement: replacement)
    }

    private func makeObservation() -> RawObservation {
        let unit: ObservationUnit = switch kind {
        case .basalRate: .unitsPerHour
        case .glucose: .millimolesPerLiter
        case .bolus: .insulinUnits
        case .carbohydrate: .grams
        case .eventStem: .none
        }
        let amountState: ObservationAmountState = parsedAmount == nil ? .amountUnknown : .known
        return RawObservation(
            id: id,
            kind: kind,
            startDate: startDate,
            endDate: kind == .basalRate ? endDate : nil,
            amount: parsedAmount,
            unit: unit,
            amountState: amountState,
            boundingBox: original?.boundingBox ?? .init(x: 0, y: 0, width: 0, height: 0),
            candidates: original?.candidates ?? [],
            confidence: .init(overall: 1, geometry: original == nil ? 0 : 1, recognition: 1, calibration: 1),
            provenance: .userCorrection,
            sourceIdentifier: original?.sourceIdentifier
        )
    }
}

private struct ObservationDraftCard: View {
    @Binding var draft: ObservationDraft
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                HStack {
                    Label(kindTitle(draft.kind), systemImage: kindSymbol(draft.kind))
                        .font(.headline)
                    Spacer()
                    Text(draft.original == nil ? "Neu" : "Erkannt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Picker("Typ", selection: $draft.kind) {
                Text("Basalrate").tag(ObservationKind.basalRate)
                Text("Glukose").tag(ObservationKind.glucose)
                Text("Bolus").tag(ObservationKind.bolus)
                Text("Kohlenhydrate").tag(ObservationKind.carbohydrate)
                Text("Unklassifiziert").tag(ObservationKind.eventStem)
            }
            DatePicker("Zeit", selection: $draft.startDate)
            if draft.kind == .basalRate {
                DatePicker(
                    "Ende",
                    selection: Binding(
                        get: { draft.endDate ?? draft.startDate.addingTimeInterval(300) },
                        set: { draft.endDate = $0 }
                    )
                )
            }
            TextField("Menge", text: $draft.amountText)
                .keyboardType(.decimalPad)
            Toggle("Löschen", isOn: $draft.isDeleted)
                .tint(.red)
        }
        .disabled(draft.isDeleted && draft.original == nil)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .opacity(draft.isDeleted ? 0.55 : 1)
    }

    private func kindTitle(_ kind: ObservationKind) -> String {
        switch kind {
        case .basalRate: "Basalrate"
        case .glucose: "Glukose"
        case .bolus: "Bolus"
        case .carbohydrate: "Kohlenhydrate"
        case .eventStem: "Unklassifiziertes Ereignis"
        }
    }

    private func kindSymbol(_ kind: ObservationKind) -> String {
        switch kind {
        case .basalRate: "waveform.path"
        case .glucose: "drop.fill"
        case .bolus: "syringe.fill"
        case .carbohydrate: "fork.knife"
        case .eventStem: "questionmark.circle"
        }
    }
}

private struct ScreenshotObservationOverlay: View {
    @Environment(\.displayScale) private var displayScale
    let caseID: UUID
    let library: CaseLibraryStore
    let observations: [RawObservation]
    @Binding var selectedObservationID: UUID?
    @State private var image: UIImage?
    @State private var aspectRatio = 2.0

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Originaler CamAPS-FX-Screenshot")
            } else {
                ProgressView()
            }
            GeometryReader { proxy in
                ForEach(observations) { observation in
                    overlayButton(observation, size: proxy.size)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 12))
        .task(id: displayScale) { await loadImage() }
    }

    private func overlayButton(_ observation: RawObservation, size: CGSize) -> some View {
        let box = observation.boundingBox
        return Button {
            selectedObservationID = observation.id
        } label: {
            Rectangle()
                .fill(color(observation.kind).opacity(selectedObservationID == observation.id ? 0.22 : 0.08))
                .overlay {
                    Rectangle().stroke(color(observation.kind), lineWidth: selectedObservationID == observation.id ? 3 : 1)
                }
        }
        .buttonStyle(.plain)
        .frame(width: max(1, box.width * size.width), height: max(1, box.height * size.height))
        .position(
            x: (box.x + box.width / 2) * size.width,
            y: (box.y + box.height / 2) * size.height
        )
        .accessibilityLabel("\(kindTitle(observation.kind)), Konfidenz \(Int(observation.confidence.overall * 100)) Prozent")
    }

    private func loadImage() async {
        guard let data = try? await library.screenshotData(caseID: caseID),
              let metadata = ImageMetadataReader.read(data: data) else { return }
        aspectRatio = metadata.pixelHeight > 0
            ? Double(metadata.pixelWidth) / Double(metadata.pixelHeight)
            : 2
        let thumbnail = await ImageDownsampler().thumbnailData(
            from: data,
            maximumPixelSize: 1_600 * displayScale
        )
        if let thumbnail {
            image = UIImage(data: thumbnail)
        }
    }

    private func color(_ kind: ObservationKind) -> Color {
        switch kind {
        case .basalRate: .blue
        case .glucose: .black
        case .bolus: .indigo
        case .carbohydrate: .orange
        case .eventStem: .red
        }
    }

    private func kindTitle(_ kind: ObservationKind) -> String {
        switch kind {
        case .basalRate: "Basalrate"
        case .glucose: "Glukose"
        case .bolus: "Bolus"
        case .carbohydrate: "Kohlenhydrate"
        case .eventStem: "Unklassifiziert"
        }
    }
}
