enum SetupText {
    static func documents(_ count: Int) -> String { "\(count) \(count == 1 ? "Dokument" : "Dokumente")" }
    static func pages(_ count: Int) -> String { "\(count) \(count == 1 ? "Seite" : "Seiten")" }
}
