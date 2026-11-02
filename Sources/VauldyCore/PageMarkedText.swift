import Foundation

public enum VaultPageMarkedText {
    public struct Section: Equatable, Sendable {
        public var page: Int?
        public var text: String
        public init(page: Int?, text: String) { self.page = page; self.text = text }
    }

    public static func sections(in text: String) -> [Section] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else {
            return [Section(page: nil, text: text)]
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return [Section(page: nil, text: text)]
        }

        var result: [Section] = []
        if let first = matches.first, let range = Range(first.range, in: text) {
            let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { result.append(Section(page: nil, text: prefix)) }
        }
        for (index, match) in matches.enumerated() {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let page = Int(text[numberRange]),
                  let markerRange = Range(match.range, in: text) else {
                continue
            }

            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextMarker = Range(matches[index + 1].range, in: text) {
                contentEnd = nextMarker.lowerBound
            } else {
                contentEnd = text.endIndex
            }

            result.append(
                Section(
                    page: page,
                    text: text[markerRange.upperBound..<contentEnd]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return result.isEmpty ? [Section(page: nil, text: text)] : result
    }

    static func reference(documentId: UUID, page: Int?) -> String {
        page.map { "[Ref:\(documentId.uuidString):S.\($0)]" }
            ?? "[Ref:\(documentId.uuidString)]"
    }

    private static let markerPattern = #"(?m)^---\s*Seite\s*(\d+)\s*---\s*$"#
}
