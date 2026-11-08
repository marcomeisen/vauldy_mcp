import Foundation
import CryptoKit
import VauldyCore
import Darwin

struct PDFInput: Decodable {
    struct Page: Decodable { let id: String; let image: String; let sha256: String }
    let id: String; let pdf: String; let sha256: String; let pages: [Page]
}
struct PDFOutput: Encodable {
    let id: String; let inputSHA256: String; let milliseconds: Double
    let rssPeakBytes: Int; let pages: [LocalOCRPage]
}
@main struct GermanPDFProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let corpus = root.appendingPathComponent("corpus/frozen")
        let inputs = try JSONDecoder().decode([PDFInput].self, from: Data(contentsOf: corpus.appendingPathComponent("requests.json")))
        let out = root.appendingPathComponent("results/apple")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let ocr = NativeLocalDocumentOCR()
        for input in inputs {
            let file = corpus.appendingPathComponent(input.pdf)
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == input.sha256 else { fatalError("Frozen PDF changed") }
            let start = ContinuousClock.now
            let result = try await ocr.recognize(file: file, progress: { _ in })
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            guard result.pages.count == input.pages.count,
                  result.pages.allSatisfy({ $0.info.metrics?.cacheHit != true }),
                  result.pages.map({$0.info.page}) == Array(1...input.pages.count)
            else { fatalError("Physical pages or fresh recognition lost") }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let record = PDFOutput(id: input.id, inputSHA256: hash, milliseconds: ms,
                                   rssPeakBytes: Int(usage.ru_maxrss), pages: result.pages)
            try encoder.encode(record).write(to: out.appendingPathComponent(input.id + ".json"), options: .atomic)
            print("\(input.id) pages=\(result.pages.count) milliseconds=\(ms) rssPeakBytes=\(usage.ru_maxrss)")
            fflush(stdout)
        }
    }
}
