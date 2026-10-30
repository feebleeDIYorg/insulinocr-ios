import Foundation
import XCTest
@testable import InsulinOCR

@MainActor
final class ImportQueueTests: XCTestCase {
    func testQueueRejectsManifestPathTraversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportQueuePathTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AppGroupImportQueue(queueRootOverride: root)
        let manifest = try await queue.enqueue(
            imageData: Data("original".utf8),
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            captureTime: .now,
            captureTimeSource: .importTime
        )
        let directory = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        let malicious = ImportManifest(
            id: manifest.id,
            originalFilename: manifest.originalFilename,
            uniformTypeIdentifier: manifest.uniformTypeIdentifier,
            imageFilename: "../outside.png",
            byteCount: manifest.byteCount,
            sha256: manifest.sha256,
            captureTime: manifest.captureTime,
            captureTimeSource: manifest.captureTimeSource,
            queuedAt: manifest.queuedAt
        )
        try JSONEncoder.insulinOCR.encode(malicious).write(
            to: directory.appendingPathComponent("manifest.json"), options: .atomic
        )
        do {
            _ = try await queue.pendingImports()
            XCTFail("Path traversal must be rejected before reading image bytes")
        } catch let error as ImportQueueError {
            guard case .invalidManifest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQueuePreservesOriginalBytesAndRemovesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AppGroupImportQueue(queueRootOverride: root)
        let original = Data([0x89, 0x50, 0x4e, 0x47, 0x01, 0x02, 0x03])

        let manifest = try await queue.enqueue(
            imageData: original,
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            captureTimeSource: .fileMetadata
        )
        let pending = try await queue.pendingImports()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(
            try JSONEncoder.insulinOCR.encode(pending[0].manifest),
            try JSONEncoder.insulinOCR.encode(manifest)
        )
        XCTAssertEqual(
            pending[0].manifest.queuedAt.timeIntervalSince1970,
            manifest.queuedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(try Data(contentsOf: pending[0].imageURL), original)
        XCTAssertEqual(manifest.sha256, AppGroupImportQueue.sha256(original))

        try await queue.remove(pending[0])
        let remaining = try await queue.pendingImports()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testQueueRejectsTamperedImageBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportQueueTamperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AppGroupImportQueue(queueRootOverride: root)

        let manifest = try await queue.enqueue(
            imageData: Data("original".utf8),
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            captureTime: .now,
            captureTimeSource: .importTime
        )
        let storedImage = root
            .appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            .appendingPathComponent(manifest.imageFilename)
        try Data("tampered".utf8).write(to: storedImage, options: .atomic)

        do {
            _ = try await queue.pendingImports()
            XCTFail("A checksum mismatch must fail closed.")
        } catch let error as ImportQueueError {
            guard case .checksumMismatch = error else {
                return XCTFail("Unexpected import error: \(error)")
            }
        }
    }
}
