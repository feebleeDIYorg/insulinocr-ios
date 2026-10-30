import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

private struct SharedImportManifest: Codable, Sendable {
    let id: UUID
    let originalFilename: String
    let uniformTypeIdentifier: String
    let imageFilename: String
    let byteCount: Int
    let sha256: String
    let captureTime: Date
    let captureTimeSource: String
    let queuedAt: Date
}

private enum ShareImportError: LocalizedError {
    case exactlyOneImageRequired
    case imageUnavailable
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .exactlyOneImageRequired:
            "Bitte genau einen CamAPS-FX-Screenshot teilen."
        case .imageUnavailable:
            "Der Screenshot konnte nicht gelesen werden."
        case .appGroupUnavailable:
            "Die gemeinsame Importablage ist nicht verfügbar."
        }
    }
}

private final class ItemProviderBox: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
}

@MainActor
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        beginImport()
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground
        titleLabel.text = "InsulinOCR"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        statusLabel.text = "Screenshot wird vorbereitet …"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        progressView.startAnimating()
        let stack = UIStackView(arrangedSubviews: [titleLabel, progressView, statusLabel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func beginImport() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        guard providers.count == 1, let provider = providers.first else {
            show(error: ShareImportError.exactlyOneImageRequired)
            return
        }

        let providerBox = ItemProviderBox(provider)
        Task {
            do {
                let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) ?? UTType.png.identifier
                let data = try await Self.loadData(from: providerBox, typeIdentifier: typeIdentifier)
                let captureTime = Self.captureTime(from: data)
                let writer = SharedQueueWriter()
                try await writer.enqueue(
                    data: data,
                    suggestedName: provider.suggestedName ?? "CamAPS-Screenshot",
                    typeIdentifier: typeIdentifier,
                    captureTime: captureTime ?? .now,
                    captureTimeSource: captureTime == nil ? "importTime" : "imageMetadata"
                )
                progressView.stopAnimating()
                statusLabel.text = "Importiert. Die Analyse startet beim nächsten Öffnen von InsulinOCR."
                try? await Task.sleep(for: .milliseconds(650))
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                show(error: error)
            }
        }
    }

    private func show(error: any Error) {
        progressView.stopAnimating()
        statusLabel.text = error.localizedDescription
        let alert = UIAlertController(
            title: "Import nicht möglich",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Schließen", style: .cancel) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: error)
        })
        present(alert, animated: true)
    }

    nonisolated private static func loadData(
        from providerBox: ItemProviderBox,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            providerBox.provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ShareImportError.imageUnavailable)
                }
            }
        }
    }

    nonisolated private static func captureTime(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}

private actor SharedQueueWriter {
    private let fileManager = FileManager.default

    func enqueue(
        data: Data,
        suggestedName: String,
        typeIdentifier: String,
        captureTime: Date,
        captureTimeSource: String
    ) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: BuildConfiguration.appGroupIdentifier
        ) else {
            throw ShareImportError.appGroupUnavailable
        }
        let root = container.appendingPathComponent("ImportQueue", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)

        let id = UUID()
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "img"
        let imageFilename = "original.\(fileExtension)"
        let partial = root.appendingPathComponent(".partial-\(id.uuidString)", isDirectory: true)
        let final = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

        let manifest = SharedImportManifest(
            id: id,
            originalFilename: suggestedName,
            uniformTypeIdentifier: typeIdentifier,
            imageFilename: imageFilename,
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            captureTime: captureTime,
            captureTimeSource: captureTimeSource,
            queuedAt: .now
        )
        let imageURL = partial.appendingPathComponent(imageFilename)
        try data.write(to: imageURL, options: [.atomic])
        try protect(imageURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestURL = partial.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        try protect(manifestURL)

        try fileManager.moveItem(at: partial, to: final)
        try protect(final)
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}
