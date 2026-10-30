import CloudKit
import CryptoKit
import Foundation

enum CloudSyncState: Equatable, Sendable {
    case disabled
    case starting
    case syncing
    case failed(String)
}

enum CloudRemoteChange: Sendable {
    case merge(CloudCaseArchive)
    case tombstone(UUID)
}

enum CloudSyncServiceError: Error, LocalizedError, Equatable {
    case disabled
    case malformedRecord(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "iCloud-Synchronisierung ist nicht aktiviert."
        case .malformedRecord(let reason):
            "Der iCloud-Datensatz ist unvollständig: \(reason)"
        case .unsupportedSchema(let version):
            "Die iCloud-Daten verwenden das nicht unterstützte Schema \(version)."
        }
    }
}

protocol CloudSyncServiceProtocol: Sendable {
    func start() async throws
    func stop() async
    func state() async -> CloudSyncState
    func enqueue(_ archive: CloudCaseArchive) async throws
}

/// Explicit opt-in CloudKit mirror. SwiftData never opens a CloudKit-backed
/// container; failed or unavailable sync therefore cannot remove local data.
actor CloudSyncService: CloudSyncServiceProtocol {
    typealias RemoteChangeHandler = @Sendable (CloudRemoteChange) async throws -> Void

    static let zoneName = "InsulinOCRCases"
    static let recordType = "InsulinOCRCase"

    private let containerIdentifier: String
    private let fileManager: FileManager
    private let storageRootOverride: URL?
    private var currentState: CloudSyncState = .disabled
    private var syncEngine: CKSyncEngine?
    private var syncDelegate: SyncEngineDelegate?
    private var startGeneration: UUID?
    private var preparedRecords: [CKRecord.ID: PreparedRecord] = [:]
    private var remoteChangeHandler: RemoteChangeHandler?

    init(
        containerIdentifier: String,
        fileManager: FileManager = .default,
        storageRootOverride: URL? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
        self.storageRootOverride = storageRootOverride
    }

    func setRemoteChangeHandler(_ handler: RemoteChangeHandler?) {
        remoteChangeHandler = handler
    }

    func state() async -> CloudSyncState {
        currentState
    }

    func start() async throws {
        guard syncEngine == nil else { return }
        guard currentState != .starting else { return }
        let generation = UUID()
        startGeneration = generation
        currentState = .starting
        do {
            let container = CKContainer(identifier: containerIdentifier)
            let accountStatus = try await container.accountStatus()
            guard startGeneration == generation else {
                throw CloudSyncServiceError.disabled
            }
            guard accountStatus == .available else {
                throw NSError(
                    domain: "CloudSyncService",
                    code: Int(accountStatus.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "iCloud ist für diesen Account nicht verfügbar."]
                )
            }

            try prepareStorage()
            preparedRecords = try loadPreparedRecords()
            let delegate = SyncEngineDelegate()
            delegate.owner = self
            let configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: try loadStateSerialization(),
                delegate: delegate
            )
            let engine = CKSyncEngine(configuration)
            syncDelegate = delegate
            syncEngine = engine
            currentState = .syncing
            scheduleZoneAndPreparedRecords(on: engine)
            try await replayIncomingChanges()
            guard startGeneration == generation else {
                throw CloudSyncServiceError.disabled
            }
            try await engine.fetchChanges()
        } catch {
            if startGeneration == generation {
                syncDelegate?.owner = nil
                syncDelegate = nil
                syncEngine = nil
                currentState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func stop() async {
        startGeneration = nil
        syncDelegate?.owner = nil
        syncDelegate = nil
        syncEngine = nil
        preparedRecords.removeAll(keepingCapacity: false)
        currentState = .disabled
    }

    func enqueue(_ archive: CloudCaseArchive) async throws {
        guard let syncEngine else { throw CloudSyncServiceError.disabled }
        try archive.validate()
        let prepared = try persist(archive, in: outgoingRoot())
        preparedRecords[prepared.recordID] = prepared
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(prepared.recordID)])
        currentState = .syncing
    }

    func sendPendingChanges() async throws {
        guard let syncEngine else { throw CloudSyncServiceError.disabled }
        try await syncEngine.sendChanges()
    }

    private func scheduleZoneAndPreparedRecords(on engine: CKSyncEngine) {
        let zone = CKRecordZone(zoneID: Self.zoneID)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        let changes = preparedRecords.keys.map(CKSyncEngine.PendingRecordZoneChange.saveRecord)
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    fileprivate func nextRecordBatch(
        _ context: CKSyncEngine.SendChangesContext,
        engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = engine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.record(for: recordID)
        }
    }

    fileprivate func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try persistStateSerialization(update.stateSerialization)
            case .accountChange(let change):
                switch change.changeType {
                case .signIn:
                    currentState = .syncing
                case .signOut, .switchAccounts:
                    currentState = .failed("Der iCloud-Account wurde geändert. Lokale Daten bleiben erhalten.")
                @unknown default:
                    currentState = .failed("Der iCloud-Accountstatus hat sich unerwartet geändert.")
                }
            case .fetchedRecordZoneChanges(let changes):
                try await receive(changes)
                if syncEngine === engine {
                    currentState = .syncing
                }
            case .sentRecordZoneChanges(let changes):
                try await finish(changes, engine: engine)
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                    engine.state.add(
                        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                    )
                }
            case .sentDatabaseChanges(let changes):
                if !changes.failedZoneSaves.isEmpty {
                    currentState = .failed("Die private iCloud-Zone konnte nicht angelegt werden.")
                }
            case .didFetchRecordZoneChanges(let result):
                if let error = result.error {
                    currentState = .failed(error.localizedDescription)
                }
            case .willFetchChanges, .willFetchRecordZoneChanges,
                 .didFetchChanges, .willSendChanges, .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            if syncEngine === engine {
                currentState = .failed(error.localizedDescription)
            }
        }
    }

    private func record(for recordID: CKRecord.ID) async -> CKRecord? {
        guard let prepared = preparedRecords[recordID] else { return nil }
        do {
            let record = try restoredRecord(for: recordID)
                ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            record["schemaVersion"] = NSNumber(value: prepared.manifest.schemaVersion)
            record["caseID"] = prepared.manifest.caseID.uuidString as NSString
            record["modifiedAt"] = prepared.manifest.modifiedAt as NSDate
            record["tombstone"] = NSNumber(value: prepared.manifest.isDeletedTombstone)
            record["manifestSHA256"] = prepared.manifestSHA256 as NSString
            record["manifest"] = CKAsset(fileURL: prepared.manifestURL)
            record["originalImage"] = prepared.originalImageURL.map(CKAsset.init(fileURL:))
            record["diagnosticImage"] = prepared.diagnosticImageURL.map(CKAsset.init(fileURL:))
            return record
        } catch {
            currentState = .failed(error.localizedDescription)
            return nil
        }
    }

    private func receive(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async throws {
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordType == Self.recordType else { continue }
            let archive = try archive(from: record)
            try persistSystemFields(record)
            let prepared = try persist(archive, in: incomingRoot())
            do {
                try await remoteChangeHandler?(.merge(archive))
                try removeDirectory(prepared.directoryURL)
            } catch {
                // The incoming snapshot remains encrypted on disk and is replayed
                // at the next start; the CloudKit cursor may safely advance.
                throw error
            }
        }
        for deletion in changes.deletions where deletion.recordType == Self.recordType {
            guard let caseID = UUID(uuidString: deletion.recordID.recordName) else { continue }
            let markerURL = try persistIncomingTombstone(caseID)
            do {
                try await remoteChangeHandler?(.tombstone(caseID))
                try removeStoredItem(markerURL)
            } catch {
                // Keep a protected local journal entry. The CloudKit cursor may
                // advance without losing the deletion on the next opt-in start.
                throw error
            }
        }
    }

    private func finish(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        engine: CKSyncEngine
    ) async throws {
        for record in changes.savedRecords {
            try persistSystemFields(record)
            guard let prepared = preparedRecords[record.recordID] else { continue }
            let sentManifestSHA256 = record["manifestSHA256"] as? String
            if sentManifestSHA256 == prepared.manifestSHA256 {
                preparedRecords[record.recordID] = nil
                try removeOutgoingGenerations(for: record.recordID)
            }
        }
        for recordID in changes.deletedRecordIDs {
            preparedRecords[recordID] = nil
        }
        for failure in changes.failedRecordSaves {
            if failure.error.code == .serverRecordChanged,
               let serverRecord = failure.error.serverRecord,
               let local = preparedRecords[failure.record.recordID] {
                try await resolveConflict(serverRecord: serverRecord, local: local, engine: engine)
            } else if failure.error.code == .zoneNotFound {
                engine.state.add(
                    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                )
                engine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                )
            } else if !Self.isRetryable(failure.error) {
                currentState = .failed(failure.error.localizedDescription)
            }
        }
        for (_, error) in changes.failedRecordDeletes where !Self.isRetryable(error) {
            currentState = .failed(error.localizedDescription)
        }
    }

    private func resolveConflict(
        serverRecord: CKRecord,
        local: PreparedRecord,
        engine: CKSyncEngine
    ) async throws {
        let server = try archive(from: serverRecord)
        try persistSystemFields(serverRecord)
        let localArchive = try archive(from: local)
        let merged = localArchive.merging(server)
        try merged.validate()
        try await remoteChangeHandler?(.merge(merged))
        let prepared = try persist(merged, in: outgoingRoot())
        preparedRecords[prepared.recordID] = prepared
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(prepared.recordID)])
    }

    private func replayIncomingChanges() async throws {
        let tombstoneFiles = try fileManager.contentsOfDirectory(
            at: incomingTombstonesRoot(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for markerURL in tombstoneFiles where markerURL.pathExtension == "tombstone" {
            guard let caseID = UUID(uuidString: markerURL.deletingPathExtension().lastPathComponent) else {
                try removeStoredItem(markerURL)
                continue
            }
            try await remoteChangeHandler?(.tombstone(caseID))
            try removeStoredItem(markerURL)
        }

        let root = try incomingRoot()
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories where fileManager.fileExists(
            atPath: directory.appendingPathComponent("manifest.iocr-lzfse").path
        ) {
            let prepared = try loadPreparedRecord(directory: directory)
            let archive = try archive(from: prepared)
            try await remoteChangeHandler?(.merge(archive))
            try removeDirectory(directory)
        }
    }

    private func archive(from record: CKRecord) throws -> CloudCaseArchive {
        guard record.recordType == Self.recordType else {
            throw CloudSyncServiceError.malformedRecord("recordType ist ungültig")
        }
        guard record.recordID.zoneID == Self.zoneID else {
            throw CloudSyncServiceError.malformedRecord("Datensatz liegt außerhalb der privaten Case-Zone")
        }
        guard let recordCaseID = UUID(uuidString: record.recordID.recordName) else {
            throw CloudSyncServiceError.malformedRecord("recordName ist keine Case-ID")
        }
        guard let caseIDField = record["caseID"] as? String,
              caseIDField == recordCaseID.uuidString else {
            throw CloudSyncServiceError.malformedRecord("caseID stimmt nicht mit recordName überein")
        }
        guard let schema = record["schemaVersion"] as? NSNumber else {
            throw CloudSyncServiceError.malformedRecord("schemaVersion fehlt")
        }
        guard schema.intValue == CloudCaseManifest.currentSchemaVersion else {
            throw CloudSyncServiceError.unsupportedSchema(schema.intValue)
        }
        guard let manifestAsset = record["manifest"] as? CKAsset,
              let manifestURL = manifestAsset.fileURL else {
            throw CloudSyncServiceError.malformedRecord("Manifest-Asset fehlt")
        }
        let manifest = try CloudSyncCodec.decode(Data(contentsOf: manifestURL))
        guard manifest.caseID == recordCaseID else {
            throw CloudSyncServiceError.malformedRecord("Manifest gehört zu einem anderen Case")
        }
        guard manifest.schemaVersion == schema.intValue else {
            throw CloudSyncServiceError.malformedRecord("Schemafelder stimmen nicht überein")
        }
        guard let tombstone = record["tombstone"] as? NSNumber,
              tombstone.boolValue == manifest.isDeletedTombstone else {
            throw CloudSyncServiceError.malformedRecord("Tombstone-Felder stimmen nicht überein")
        }
        if let expectedDigest = record["manifestSHA256"] as? String {
            let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            guard Self.sha256(manifestData) == expectedDigest else {
                throw CloudSyncServiceError.malformedRecord("Manifest-Prüfsumme ist ungültig")
            }
        }
        let original = try Self.assetData(record["originalImage"] as? CKAsset)
        let diagnostic = try Self.assetData(record["diagnosticImage"] as? CKAsset)
        let archive = CloudCaseArchive(
            manifest: manifest,
            originalImageData: original,
            diagnosticImageData: diagnostic
        )
        try archive.validate()
        return archive
    }

    private func archive(from prepared: PreparedRecord) throws -> CloudCaseArchive {
        let archive = CloudCaseArchive(
            manifest: prepared.manifest,
            originalImageData: try prepared.originalImageURL.map { try Data(contentsOf: $0) },
            diagnosticImageData: try prepared.diagnosticImageURL.map { try Data(contentsOf: $0) }
        )
        try archive.validate()
        return archive
    }

    private func persist(_ archive: CloudCaseArchive, in root: URL) throws -> PreparedRecord {
        try archive.validate()
        let directoryName = "\(archive.manifest.caseID.uuidString)_\(UUID().uuidString)"
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        let manifestURL = directory.appendingPathComponent("manifest.iocr-lzfse")
        let manifestData = try CloudSyncCodec.encode(archive.manifest)
        try writeProtected(manifestData, to: manifestURL)

        let originalURL = directory.appendingPathComponent("original.asset")
        let diagnosticURL = directory.appendingPathComponent("diagnostic.asset")
        if archive.manifest.isDeletedTombstone {
            try removeIfPresent(originalURL)
            try removeIfPresent(diagnosticURL)
        } else {
            if let data = archive.originalImageData {
                try writeProtected(data, to: originalURL)
            }
            if let data = archive.diagnosticImageData {
                try writeProtected(data, to: diagnosticURL)
            }
        }
        return PreparedRecord(
            recordID: CKRecord.ID(
                recordName: archive.manifest.caseID.uuidString,
                zoneID: Self.zoneID
            ),
            manifest: archive.manifest,
            manifestSHA256: Self.sha256(manifestData),
            directoryURL: directory,
            manifestURL: manifestURL,
            originalImageURL: fileManager.fileExists(atPath: originalURL.path) ? originalURL : nil,
            diagnosticImageURL: fileManager.fileExists(atPath: diagnosticURL.path) ? diagnosticURL : nil
        )
    }

    private func loadPreparedRecords() throws -> [CKRecord.ID: PreparedRecord] {
        let directories = try fileManager.contentsOfDirectory(
            at: outgoingRoot(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [CKRecord.ID: PreparedRecord] = [:]
        for directory in directories {
            let prepared = try loadPreparedRecord(directory: directory)
            _ = try archive(from: prepared)
            if let current = result[prepared.recordID] {
                let shouldReplace = prepared.manifest.modifiedAt > current.manifest.modifiedAt
                    || (prepared.manifest.modifiedAt == current.manifest.modifiedAt
                        && prepared.manifestSHA256 > current.manifestSHA256)
                if shouldReplace {
                    try removeStoredItem(current.directoryURL)
                    result[prepared.recordID] = prepared
                } else {
                    try removeStoredItem(prepared.directoryURL)
                }
            } else {
                result[prepared.recordID] = prepared
            }
        }
        return result
    }

    private func loadPreparedRecord(directory: URL) throws -> PreparedRecord {
        let manifestURL = directory.appendingPathComponent("manifest.iocr-lzfse")
        let manifest = try CloudSyncCodec.decode(Data(contentsOf: manifestURL))
        let originalURL = directory.appendingPathComponent("original.asset")
        let diagnosticURL = directory.appendingPathComponent("diagnostic.asset")
        return PreparedRecord(
            recordID: CKRecord.ID(recordName: manifest.caseID.uuidString, zoneID: Self.zoneID),
            manifest: manifest,
            manifestSHA256: Self.sha256(try Data(contentsOf: manifestURL, options: [.mappedIfSafe])),
            directoryURL: directory,
            manifestURL: manifestURL,
            originalImageURL: fileManager.fileExists(atPath: originalURL.path) ? originalURL : nil,
            diagnosticImageURL: fileManager.fileExists(atPath: diagnosticURL.path) ? diagnosticURL : nil
        )
    }

    private func restoredRecord(for recordID: CKRecord.ID) throws -> CKRecord? {
        let url = try systemFieldsRoot().appendingPathComponent("\(recordID.recordName).record")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKRecord.self,
            from: Data(contentsOf: url)
        )
    }

    private func persistSystemFields(_ record: CKRecord) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let url = try systemFieldsRoot().appendingPathComponent("\(record.recordID.recordName).record")
        try writeProtected(archiver.encodedData, to: url)
    }

    private func loadStateSerialization() throws -> CKSyncEngine.State.Serialization? {
        let url = try stateURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: Data(contentsOf: url)
        )
    }

    private func persistStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization
    ) throws {
        try writeProtected(try JSONEncoder().encode(serialization), to: stateURL())
    }

    private func prepareStorage() throws {
        for directory in [
            try storageRoot(),
            try outgoingRoot(),
            try incomingRoot(),
            try incomingTombstonesRoot(),
            try systemFieldsRoot(),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protect(directory)
        }
    }

    private func storageRoot() throws -> URL {
        if let storageRootOverride { return storageRootOverride }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("InsulinOCR", isDirectory: true)
            .appendingPathComponent("CloudSync", isDirectory: true)
    }

    private func outgoingRoot() throws -> URL {
        try storageRoot().appendingPathComponent("Outgoing", isDirectory: true)
    }

    private func incomingRoot() throws -> URL {
        try storageRoot().appendingPathComponent("Incoming", isDirectory: true)
    }

    private func systemFieldsRoot() throws -> URL {
        try storageRoot().appendingPathComponent("SystemFields", isDirectory: true)
    }

    private func incomingTombstonesRoot() throws -> URL {
        try incomingRoot().appendingPathComponent("Tombstones", isDirectory: true)
    }

    private func stateURL() throws -> URL {
        try storageRoot().appendingPathComponent("engine-state.json")
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try protect(url)
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeDirectory(_ url: URL) throws {
        try removeStoredItem(url)
    }

    private func removeStoredItem(_ url: URL) throws {
        let rootPath = try storageRoot().standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try removeIfPresent(url)
    }

    private func persistIncomingTombstone(_ caseID: UUID) throws -> URL {
        let markerURL = try incomingTombstonesRoot()
            .appendingPathComponent(caseID.uuidString)
            .appendingPathExtension("tombstone")
        try writeProtected(Data(caseID.uuidString.utf8), to: markerURL)
        return markerURL
    }

    private func removeOutgoingGenerations(for recordID: CKRecord.ID) throws {
        let directories = try fileManager.contentsOfDirectory(
            at: outgoingRoot(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            let manifestURL = directory.appendingPathComponent("manifest.iocr-lzfse")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let manifest = try? CloudSyncCodec.decode(Data(contentsOf: manifestURL)),
                  manifest.caseID.uuidString == recordID.recordName else {
                continue
            }
            try removeStoredItem(directory)
        }
    }

    private static func assetData(_ asset: CKAsset?) throws -> Data? {
        guard let url = asset?.fileURL else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .resultsTruncated:
            true
        default:
            false
        }
    }

    private static let zoneID = CKRecordZone.ID(zoneName: zoneName)
}

private struct PreparedRecord: Sendable {
    let recordID: CKRecord.ID
    let manifest: CloudCaseManifest
    let manifestSHA256: String
    let directoryURL: URL
    let manifestURL: URL
    let originalImageURL: URL?
    let diagnosticImageURL: URL?
}

private final class SyncEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: CloudSyncService?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handle(event, engine: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextRecordBatch(context, engine: syncEngine)
    }
}
