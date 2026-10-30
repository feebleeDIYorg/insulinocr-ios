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
                if let payload = try? encoder.encode(Failure(error: error.localizedDescription)) {
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
        switch await engine.analyzeRetainingFailure(ScreenshotAnalysisRequest(imageData: data)) {
        case .success(let analysis): result = analysis
        case .failure(let failure):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(failure.rawTextObservations).write(
                to: output.appendingPathExtension("raw-ocr.json"), options: .atomic)
            try encoder.encode(failure).write(
                to: output.appendingPathExtension("failed-analysis.json"), options: .atomic)
            throw failure
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output, options: .atomic)
        print("Analysis complete; inspect the local JSON for quality and warnings.")
    }
}
