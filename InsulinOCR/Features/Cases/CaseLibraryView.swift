import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CaseLibraryView: View {
    @Bindable var appModel: AppModel
    @Bindable var library: CaseLibraryStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var deletionID: UUID?
    @State private var deletionError: String?

    var body: some View {
        NavigationSplitView {
            caseList
                .navigationTitle("Cases")
                .toolbar { libraryToolbar }
        } detail: {
            if let selectedCaseID = library.selectedCaseID,
               let record = library.caseRecord(id: selectedCaseID) {
                CaseDetailView(appModel: appModel, library: library, record: record)
            } else {
                EmptyCaseSelectionView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsView(appModel: appModel, settings: appModel.settings)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .alert(
            "Hinweis",
            isPresented: Binding(
                get: { appModel.importNotice != nil },
                set: { if !$0 { appModel.dismissNotice() } }
            )
        ) {
            Button("OK") { appModel.dismissNotice() }
        } message: {
            Text(appModel.importNotice ?? "")
        }
        .confirmationDialog("Case löschen?", isPresented: Binding(
            get: { deletionID != nil },
            set: { if !$0 { deletionID = nil } }
        ), titleVisibility: .visible) {
            Button("Case und Screenshot löschen", role: .destructive) {
                guard let id = deletionID else { return }
                deletionID = nil
                Task {
                    do {
                        try await library.deleteCase(caseID: id)
                        if library.selectedCaseID == id { library.selectedCaseID = nil }
                    } catch { deletionError = error.localizedDescription }
                }
            }
            Button("Abbrechen", role: .cancel) { deletionID = nil }
        } message: {
            Text("Die lokalen Bilddaten werden entfernt. Bei aktivierter iCloud-Synchronisierung wird die Löschung auch auf andere Geräte übertragen.")
        }
        .alert("Löschen fehlgeschlagen", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var caseList: some View {
        List(selection: $library.selectedCaseID) {
            if library.cases.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Cases", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Teile einen Querformat-Screenshot aus CamAPS FX oder importiere ihn hier.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(library.cases) { record in
                    NavigationLink(value: record.id) {
                        CaseRow(record: record)
                    }
                    .accessibilityIdentifier("case.row.\(record.id.uuidString)")
                    .swipeActions {
                        Button("Löschen", systemImage: "trash", role: .destructive) {
                            deletionID = record.id
                        }
                    }
                }
            }
        }
        .overlay {
            if appModel.isProcessingImports {
                ProgressView("Import wird verarbeitet …")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu("Importieren", systemImage: "square.and.arrow.down") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Aus Fotos", systemImage: "photo")
                }
                Button("Aus Dateien", systemImage: "folder") {
                    showFileImporter = true
                }
            }
            Button("Einstellungen", systemImage: "gearshape") {
                showSettings = true
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return
        }
        await appModel.importImageData(
            data,
            suggestedName: "CamAPS-Screenshot-\(Date.now.ISO8601Format()).png",
            typeIdentifier: item.supportedContentTypes.first?.identifier ?? UTType.png.identifier
        )
    }

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
            let resources = try? url.resourceValues(forKeys: [.contentTypeKey, .creationDateKey])
            let type = resources?.contentType?.identifier ?? UTType.png.identifier
            await appModel.importImageData(
                data,
                suggestedName: url.lastPathComponent,
                typeIdentifier: type,
                fileCaptureTime: resources?.creationDate
            )
        }
    }
}

private struct CaseRow: View {
    let record: CaseEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(record.title)
                .font(.headline)
                .lineLimit(1)
            Text(record.captureTime, format: .dateTime.day().month().year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            StatusBadge(status: record.status)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyCaseSelectionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Case auswählen", systemImage: "waveform.path.ecg.rectangle")
        } description: {
            Text("Wähle links einen analysierten Case aus oder importiere einen Screenshot.")
        }
    }
}
