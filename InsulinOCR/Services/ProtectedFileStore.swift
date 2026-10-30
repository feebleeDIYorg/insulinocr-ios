import CryptoKit
import Foundation

struct StoredAsset: Sendable {
    let relativePath: String
    let sha256: String
    let byteCount: Int
}

protocol CaseFileStore: Sendable {
    func saveOriginal(data: Data, caseID: UUID, filenameExtension: String) async throws -> StoredAsset
    func saveDiagnostic(data: Data, caseID: UUID, filename: String) async throws -> StoredAsset
    func read(relativePath: String) async throws -> Data
    func url(relativePath: String) async throws -> URL
    func deleteCaseDirectory(caseID: UUID) async throws
}

actor ProtectedCaseFileStore: CaseFileStore {
    private let fileManager: FileManager
    private let rootOverride: URL?

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
    }

    func saveOriginal(data: Data, caseID: UUID, filenameExtension: String) async throws -> StoredAsset {
        try save(
            data: data,
            caseID: caseID,
            filename: "original.\(filenameExtension.isEmpty ? "img" : filenameExtension)"
        )
    }

    func saveDiagnostic(data: Data, caseID: UUID, filename: String = "diagnostic.png") async throws -> StoredAsset {
        try save(data: data, caseID: caseID, filename: filename)
    }

    func read(relativePath: String) async throws -> Data {
        let target = try validatedURL(relativePath: relativePath)
        return try Data(contentsOf: target, options: [.mappedIfSafe])
    }

    func url(relativePath: String) async throws -> URL {
        try validatedURL(relativePath: relativePath)
    }

    func deleteCaseDirectory(caseID: UUID) async throws {
        let target = try root().appendingPathComponent(caseID.uuidString, isDirectory: true)
        guard target.standardizedFileURL.deletingLastPathComponent() == (try root()).standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    private func save(data: Data, caseID: UUID, filename: String) throws -> StoredAsset {
        let directory = try root().appendingPathComponent(caseID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)

        let target = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try protect(temporary)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: temporary, to: target)
        try protect(target)

        let relative = "\(caseID.uuidString)/\(filename)"
        return StoredAsset(
            relativePath: relative,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count
        )
    }

    private func root() throws -> URL {
        if let rootOverride {
            try fileManager.createDirectory(at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("InsulinOCR", isDirectory: true)
            .appendingPathComponent("Cases", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        return directory
    }

    private func validatedURL(relativePath: String) throws -> URL {
        let base = try root().standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return target
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}
