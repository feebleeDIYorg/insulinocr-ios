import Foundation
import InsulinOCRCore

@main
struct AnalyzeCommand {
    private struct Failure: Encodable {
        let status = "rejected"
        let error: String
    }

    static func main() async {
        do { try await run() }
        catch {
            if CommandLine.arguments.count == 3 {
                let output = URL(fileURLWithPath: CommandLine.arguments[2])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let payload = try? encoder.encode(Failure(error: String(describing: error))) {
                    try? payload.write(to: output, options: .atomic)
                }
            }
            FileHandle.standardError.write(Data("Analysis rejected; inspect the local failure report.\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw NSError(domain: "InsulinOCRAnalyze", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Usage: insulinocr-analyze INPUT_IMAGE OUTPUT_JSON"
            ])
        }
        let input = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        let data = try Data(contentsOf: input)
        let engine = NativeAnalysisEngine()
        let result: OCRAnalysisResult
        do {
            result = try await engine.analyze(ScreenshotAnalysisRequest(imageData: data))
        } catch {
            let raw = await engine.diagnosticTextObservations()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(raw).write(
                to: output.appendingPathExtension("raw-ocr.json"), options: .atomic
            )
            throw error
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output, options: .atomic)
        print("Analysis complete; inspect the local JSON for quality and warnings.")
    }
}
