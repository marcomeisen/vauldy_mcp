import Foundation
import VauldyCore
import Darwin

@main struct Probe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "input"
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("source/" + suite + "-order.json")))
        let out = root.appendingPathComponent("results/apple" + (suite == "input" ? "" : "-" + suite))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let engine = NativeLocalDocumentOCR()
        for name in names {
            let start = ContinuousClock.now
            let result = try await engine.recognize(file: root.appendingPathComponent("inputs/" + name), progress: { _ in })
            let duration = start.duration(to: .now)
            let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            guard result.pages.count == 1, let page = result.pages.first, page.info.metrics?.cacheHit != true else { fatalError("Fresh one-page recognition required") }
            try encoder.encode(page).write(to: out.appendingPathComponent(name + ".page.json"), options: .atomic)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let row: [String: Any] = ["file": name, "milliseconds": ms, "rssPeakBytes": usage.ru_maxrss]
            print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
        }
    }
}
