import Foundation
import Vision
import ImageIO

@main struct Probe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "png" }).sorted(by: { $0.path < $1.path }) {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = [.init(identifier: "de-DE"), .init(identifier: "en-US")]
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            request.textRecognitionOptions.useLanguageCorrection = true
            let start = Date()
            let result = try await request.perform(on: file)
            let text = result.map { $0.document.text.transcript }.joined(separator: "\n")
            try JSONEncoder().encode(result).write(to: out.appendingPathComponent(file.lastPathComponent + ".json"))
            try text.write(to: out.appendingPathComponent(file.lastPathComponent + ".txt"), atomically: true, encoding: .utf8)
            print("\(file.lastPathComponent) \(Date().timeIntervalSince(start))")
            fflush(stdout)
        }
    }
}
