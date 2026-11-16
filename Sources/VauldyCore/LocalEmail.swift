import Foundation
import CoreFoundation
import ImageIO

/// Bounded offline MIME reader. HTML is projected to plain text with no renderer,
/// network requests, scripting, or access to embedded URLs.
struct LocalEmail {
    struct Attachment {
        let name: String
        let ext: String
        let bytes: Data
    }

    let text: String
    let needsReview: Bool
    let attachments: [Attachment]

    init(_ data: Data) throws {
        let root = try Entity(data)
        guard ["subject", "from", "date", "message-id"].contains(where: { root.headers[$0] != nil }) else {
            throw LocalImportError.invalidDocument
        }
        let subject = Self.headerValue(root.headers["subject"])
        let sender = Self.headerValue(root.headers["from"])
        let date = Self.headerValue(root.headers["date"])
        var reader = Reader()
        let body = try reader.visit(root, depth: 0)
        var lines = ["E-Mail", "Betreff: " + subject]
        if !sender.isEmpty { lines.append("Absender: " + sender) }
        if !date.isEmpty {
            lines.append("Gesendet: " + date)
            if let day = Self.calendarDate(date) { lines.append("Dokumentdatum: " + day) }
        }
        text = lines.joined(separator: "\n") + "\n\n" + (body?.text ?? "")
        guard text.utf8.count <= 900_000 else { throw LocalImportError.fileTooLarge }
        needsReview = reader.incomplete
        attachments = reader.attachments
    }

    static func title(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0] == "E-Mail", lines[1].hasPrefix("Betreff:") else { return "E-Mail" }
        let subject = lines[1].dropFirst(8).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty else { return "E-Mail" }
        return String(subject.prefix(200))
    }

    private struct Body {
        let text: String
        let plain: Bool
    }

    private struct Reader {
        var attachments: [Attachment] = []
        var incomplete = false
        var parts = 0

        mutating func visit(_ entity: Entity, depth: Int, suppressBody: Bool = false) throws -> Body? {
            parts += 1
            guard depth <= 12, parts <= 128 else { throw LocalImportError.invalidDocument }
            let type = Media(entity.headers["content-type"] ?? "text/plain")
            let disposition = Media(entity.headers["content-disposition"] ?? "")
            let filename = disposition.filename("filename") ?? type.filename("name")
            let attached = disposition.kind == "attachment" || filename != nil
            if type.kind.hasPrefix("multipart/"), !attached {
                guard let boundary = type.params["boundary"], (1...70).contains(boundary.utf8.count) else {
                    throw LocalImportError.invalidDocument
                }
                let children = try entity.children(boundary: boundary)
                var bodies: [Body] = []
                for (index, child) in children.enumerated() {
                    let childEntity = try Entity(child)
                    let relatedResource = type.kind == "multipart/related" && (type.params["start"].map {
                        childEntity.headers["content-id"] != $0
                    } ?? (index != 0))
                    if let body = try visit(childEntity, depth: depth + 1, suppressBody: suppressBody || relatedResource),
                       !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bodies.append(body)
                    }
                    // Each child is smaller than the whole EML, but avoid collecting a huge decoded body.
                    if bodies.reduce(0, { $0 + $1.text.utf8.count }) > LocalDocumentStore.maximumOriginalBytes {
                        throw LocalImportError.fileTooLarge
                    }
                }
                if type.kind == "multipart/alternative" { return bodies.last(where: \.plain) ?? bodies.last }
                let combined = bodies.map(\.text).joined(separator: "\n\n")
                guard combined.utf8.count <= 900_000 else { throw LocalImportError.fileTooLarge }
                return .init(text: combined, plain: bodies.allSatisfy(\.plain))
            }
            let encoding = entity.headers["content-transfer-encoding"] ?? ""
            if attached || type.kind == "application/pdf" || type.kind.hasPrefix("image/") {
                // Inline images referenced by HTML are normally signatures or tracking resources.
                if disposition.kind != "attachment", suppressBody || entity.headers["content-id"] != nil { return nil }
                let ext = filename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
                guard type.kind == "application/pdf" || type.kind.hasPrefix("image/")
                        || LocalDocumentStore.ocrExtensions.contains(ext) else { return nil }
                guard let bytes = LocalEmail.transfer(entity.body, encoding: encoding),
                      let detected = LocalEmail.attachmentExtension(bytes) else {
                    incomplete = true
                    return nil
                }
                guard attachments.count < 24 else { throw LocalImportError.invalidDocument }
                let leaf = filename?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Anhang"
                let stem = (LocalEmail.headerValue(leaf) as NSString).deletingPathExtension
                let name = stem.isEmpty || stem == "." ? "Anhang" : String(stem.prefix(160))
                attachments.append(.init(name: "\(name).\(detected)", ext: detected, bytes: bytes))
                return nil
            }
            guard !suppressBody, ["text/plain", "text/html"].contains(type.kind) else { return nil }
            guard let data = LocalEmail.transfer(entity.body, encoding: encoding),
                  let decoded = LocalEmail.decode(data, charset: type.params["charset"]) else {
                incomplete = true
                return nil
            }
            guard decoded.utf8.count <= 900_000 else { throw LocalImportError.fileTooLarge }
            return .init(text: type.kind == "text/html" ? LocalEmail.htmlText(decoded) : LocalEmail.cleanBody(decoded),
                         plain: type.kind == "text/plain")
        }
    }

    private struct Entity {
        let headers: [String: String]
        let body: Data

        init(_ data: Data) throws {
            let prefix = data.prefix(65_540)
            let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
            guard let split = separators.compactMap({ prefix.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
                  split.lowerBound - data.startIndex <= 65_536 else { throw LocalImportError.invalidDocument }
            let raw = LocalEmail.decode(data[..<split.lowerBound], charset: nil) ?? ""
            var values: [String: String] = [:]
            var last: String?
            for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if let last, line.first?.isWhitespace == true {
                    values[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].lowercased()
                    guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { throw LocalImportError.invalidDocument }
                    if values[name] == nil {
                        values[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        last = name
                    } else { last = nil }
                } else { throw LocalImportError.invalidDocument }
            }
            headers = values
            body = data[split.upperBound...]
        }

        func children(boundary: String) throws -> [Data] {
            let marker = Data(("--" + boundary).utf8)
            var cursor = body.startIndex
            var start: Data.Index?
            var parts: [Data] = []
            while cursor < body.endIndex {
                let end = body[cursor...].firstIndex(of: 10) ?? body.endIndex
                let line = body[cursor..<end]
                if line.starts(with: marker) {
                    let suffix = line.dropFirst(marker.count).filter { ![9, 13, 32].contains($0) }
                    if suffix.isEmpty || suffix.elementsEqual([45, 45]) {
                        if let start {
                            var contentEnd = cursor
                            if contentEnd > start, body[contentEnd - 1] == 10 { contentEnd -= 1 }
                            if contentEnd > start, body[contentEnd - 1] == 13 { contentEnd -= 1 }
                            guard parts.count < 128 else { throw LocalImportError.invalidDocument }
                            parts.append(body[start..<contentEnd])
                        }
                        if !suffix.isEmpty { return parts }
                        start = min(end + 1, body.endIndex)
                    }
                }
                cursor = min(end + 1, body.endIndex)
            }
            throw LocalImportError.invalidDocument
        }
    }

    private struct Media {
        let kind: String
        var params: [String: String] = [:]
        init(_ value: String) {
            kind = String(value.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
            let matches = LocalEmail.matches(#";\s*([^;=\s]+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^;\s]+))"#, in: value)
            for match in matches {
                let key = LocalEmail.group(1, match, value).lowercased()
                let token = LocalEmail.group(2, match, value) + LocalEmail.group(3, match, value)
                params[key] = token.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
        }

        func filename(_ key: String) -> String? {
            if let extended = params[key + "*"], let name = Self.extended(extended) { return name }
            if let first = params[key + "*0*"] {
                var joined = first
                for i in 1..<24 {
                    if let next = params["\(key)*\(i)*"] { joined += next }
                    else if let next = params["\(key)*\(i)"] { joined += next }
                    else { break }
                }
                if let name = Self.extended(joined) { return name }
            }
            return params[key].map(LocalEmail.headerValue)
        }
        private static func extended(_ value: String) -> String? {
            let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return LocalEmail.decode(LocalEmail.unescape(Data(fields[2].utf8), escape: 37), charset: String(fields[0]))
        }
    }

    private static func calendarDate(_ raw: String) -> String? {
        let pattern = #"^(?:[A-Za-z]{3},\s*)?(\d{1,2} [A-Za-z]{3} [0-9]{4})\s"#
        guard let match = matches(pattern, in: raw).first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yyyy"
        guard let date = formatter.date(from: group(1, match, raw)) else { return nil }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func attachmentExtension(_ bytes: Data) -> String? {
        if bytes.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil { return "pdf" }
        guard let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image) else { return nil }
        return ["public.png":"png", "public.jpeg":"jpg", "public.tiff":"tiff", "public.heic":"heic",
                "public.heif":"heif"][type as String]
    }

    private static func transfer(_ bytes: Data, encoding: String) -> Data? {
        switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            let clean = Data(bytes.filter { ![9, 10, 13, 32].contains($0) })
            return Data(base64Encoded: clean)
        case "quoted-printable": return unescape(bytes, escape: 61)
        case "", "7bit", "8bit", "binary": return bytes
        default: return nil
        }
    }

    private static func unescape(_ bytes: Data, escape: UInt8) -> Data {
        let input = Array(bytes)
        var result = Data(capacity: input.count), i = 0
        func hex(_ x: UInt8) -> UInt8? {
            switch x {
            case 48...57: x - 48
            case 65...70: x - 55
            case 97...102: x - 87
            default: nil
            }
        }
        while i < input.count {
            if input[i] == escape {
                if escape == 61, i + 1 < input.count, input[i+1] == 10 { i += 2; continue }
                if escape == 61, i + 2 < input.count, input[i+1] == 13, input[i+2] == 10 { i += 3; continue }
                if i + 2 < input.count, let a = hex(input[i+1]), let b = hex(input[i+2]) {
                    result.append(a * 16 + b); i += 3; continue
                }
            }
            result.append(input[i]); i += 1
        }
        return result
    }

    private static func decode(_ data: Data, charset: String?) -> String? {
        if let charset, !charset.isEmpty {
            let enc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard enc != kCFStringEncodingInvalidId else { return nil }
            return String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(enc)))
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func headerValue(_ raw: String?) -> String {
        guard var text = raw else { return "" }
        text = text.replacingOccurrences(of: #"\?=\s+(?==\?)"#, with: "?=", options: .regularExpression)
        let words = matches(#"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#, in: text)
        var decoded = text
        for match in words.reversed() {
            let word = group(3, match, text)
            let bytes = group(2, match, text).lowercased() == "b" ? Data(base64Encoded: word)
                : unescape(Data(word.replacingOccurrences(of: "_", with: " ").utf8), escape: 61)
            if let bytes, let value = decode(bytes, charset: group(1, match, text)),
               let range = Range(match.range, in: decoded) { decoded.replaceSubrange(range, with: value) }
        }
        let safe = decoded.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(safe.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(512))
    }

    private static func cleanBody(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[\x00-\x08\x0B-\x1F\x7F]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\u200E\u200F\u202A-\u202E\u2066-\u2069]"#, with: "", options: .regularExpression)
    }

    private static func htmlText(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: #"(?is)<!--.*?(?:-->|$)|<(script|style|head|template)\b[^>]*>.*?(?:</\1\s*>|$)"#,
                                                   with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<([a-z][a-z0-9]*)\b(?=[^>]*(?:\shidden(?:\s|=|>)|display\s*:\s*none|visibility\s*:\s*hidden|color\s*:\s*(?:white|#fff(?:fff)?)))\s[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?(?:br|p|div|li|tr|h[1-6]|blockquote)\b[^>]*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<(?:"[^"]*"|'[^']*'|[^'">])*>"#, with: "", options: .regularExpression)
        let entities = ["amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" ", "euro":"€",
                        "auml":"ä", "ouml":"ö", "uuml":"ü", "Auml":"Ä", "Ouml":"Ö", "Uuml":"Ü", "szlig":"ß"]
        var result = ""
        var cursor = stripped.startIndex
        for match in matches(#"&(#(?:[xX][0-9a-fA-F]{1,6}|\d{1,7})|[a-zA-Z]{2,8});"#, in: stripped) {
            let code = group(1, match, stripped)
            let number = code.lowercased().hasPrefix("#x") ? UInt32(code.dropFirst(2), radix: 16)
                : code.hasPrefix("#") ? UInt32(code.dropFirst()) : nil
            if let value = entities[code] ?? number.flatMap(UnicodeScalar.init).map(String.init),
               let range = Range(match.range, in: stripped) {
                result += stripped[cursor..<range.lowerBound]
                result += value
                cursor = range.upperBound
            }
        }
        result += stripped[cursor...]
        return cleanBody(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }
    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String {
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}
