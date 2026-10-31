import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ImportManifest: Codable, Equatable, Sendable {
    let id: UUID
    let originalFilename: String
    let uniformTypeIdentifier: String
    let imageFilename: String
    let byteCount: Int
    let sha256: String
    let captureTime: Date
    let captureTimeSource: StoredCaptureTimeSource
    let queuedAt: Date
}

struct QueuedImport: Sendable {
    let directoryURL: URL
    let imageURL: URL
    let manifest: ImportManifest
}

protocol ImportQueue: Sendable {
    func enqueue(
        imageData: Data,
        originalFilename: String,
        uniformTypeIdentifier: String,
        captureTime: Date,
        captureTimeSource: StoredCaptureTimeSource
    ) async throws -> ImportManifest

    func pendingImports() async throws -> [QueuedImport]
    func remove(_ queuedImport: QueuedImport) async throws
}

enum ImportQueueError: LocalizedError {
    case appGroupUnavailable
    case invalidManifest(URL)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Die gemeinsame Importablage ist nicht verfügbar."
        case .invalidManifest:
            "Ein Importmanifest ist beschädigt."
        case .checksumMismatch:
            "Die Prüfsumme des importierten Screenshots stimmt nicht."
        }
    }
}

actor AppGroupImportQueue: ImportQueue {
    static let appGroupIdentifier = BuildConfiguration.appGroupIdentifier

    private let fileManager: FileManager
    private let queueRootOverride: URL?

    init(fileManager: FileManager = .default, queueRootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.queueRootOverride = queueRootOverride
    }

    func enqueue(
        imageData: Data,
        originalFilename: String,
        uniformTypeIdentifier: String,
        captureTime: Date,
        captureTimeSource: StoredCaptureTimeSource
    ) async throws -> ImportManifest {
        let root = try queueRoot()
        try ensureDirectory(root)

        let id = UUID()
        let type = UTType(uniformTypeIdentifier) ?? .png
        let extensionName = type.preferredFilenameExtension ?? "img"
        let imageFilename = "original.\(extensionName)"
        let manifest = ImportManifest(
            id: id,
            originalFilename: originalFilename,
            uniformTypeIdentifier: uniformTypeIdentifier,
            imageFilename: imageFilename,
            byteCount: imageData.count,
            sha256: Self.sha256(imageData),
            captureTime: captureTime,
            captureTimeSource: captureTimeSource,
            queuedAt: .now
        )

        let partialDirectory = root.appendingPathComponent(".partial-\(id.uuidString)", isDirectory: true)
        let finalDirectory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try ensureDirectory(partialDirectory)

        let imageURL = partialDirectory.appendingPathComponent(imageFilename)
        try imageData.write(to: imageURL, options: [.atomic])
        try protect(imageURL)

        let encoder = JSONEncoder.insulinOCR
        let manifestData = try encoder.encode(manifest)
        let manifestURL = partialDirectory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: [.atomic])
        try protect(manifestURL)
        try fileManager.moveItem(at: partialDirectory, to: finalDirectory)
        try protect(finalDirectory)
        return manifest
    }

    func pendingImports() async throws -> [QueuedImport] {
        let root = try queueRoot()
        try ensureDirectory(root)

        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var imports: [QueuedImport] = []
        for directory in directories {
            guard (try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.insulinOCR.decode(ImportManifest.self, from: data) else {
                throw ImportQueueError.invalidManifest(directory)
            }
            guard directory.lastPathComponent == manifest.id.uuidString,
                  !manifest.imageFilename.isEmpty,
                  manifest.imageFilename != ".",
                  manifest.imageFilename != "..",
                  !manifest.imageFilename.contains("/"),
                  !manifest.imageFilename.contains("\\"),
                  manifest.byteCount > 0 else {
                throw ImportQueueError.invalidManifest(directory)
            }
            let imageURL = directory.appendingPathComponent(manifest.imageFilename)
            let imageResources = try imageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard imageResources.isSymbolicLink != true, imageResources.isRegularFile == true else {
                throw ImportQueueError.invalidManifest(directory)
            }
            let imageData = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
            guard imageData.count == manifest.byteCount,
                  Self.sha256(imageData) == manifest.sha256 else {
                throw ImportQueueError.checksumMismatch
            }
            imports.append(QueuedImport(directoryURL: directory, imageURL: imageURL, manifest: manifest))
        }
        return imports.sorted { $0.manifest.queuedAt < $1.manifest.queuedAt }
    }

    func remove(_ queuedImport: QueuedImport) async throws {
        let root = try queueRoot().standardizedFileURL
        let target = queuedImport.directoryURL.standardizedFileURL
        guard target.deletingLastPathComponent() == root else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.removeItem(at: target)
    }

    private func queueRoot() throws -> URL {
        if let queueRootOverride {
            return queueRootOverride
        }
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw ImportQueueError.appGroupUnavailable
        }
        return container.appendingPathComponent("ImportQueue", isDirectory: true)
    }

    private func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    static var insulinOCR: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { try PreciseISO8601DateCoding.encode($0, to: $1) }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var insulinOCR: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try PreciseISO8601DateCoding.decode(from: $0) }
        return decoder
    }
}
