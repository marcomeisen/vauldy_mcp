import MCP

func chatReport(_ report: [String: Value]) throws -> String {
    guard report["inventoryComplete"] == .bool(true), let candidates = report["candidateCount"]?.intValue,
          let rows = report["rows"]?.arrayValue else { throw ChatReportError.invalid }
    var lines = ["Versicherungsrecherche abgeschlossen. \(candidates) Textkandidaten, \(rows.count) belegte Verträge."]
    if report["processingComplete"] != .bool(true) {
        lines.append("Die OCR-Abdeckung des freigegebenen Bestands ist unvollständig.")
    }
    let excluded = report["excluded"]?.objectValue ?? [:]
    for (reason, message) in [
        ("unconfirmed-text-candidate", "Textkandidaten ohne Vertragsbeleg"),
        ("source-not-searchable", "Kandidaten mit fehlender oder fehlgeschlagener Verarbeitung"),
        ("ambiguous-document", "Kandidaten mit mehrdeutiger Dokumentstruktur"),
    ] {
        if let count = excluded[reason]?.intValue, count > 0 {
            lines.append("\(message) (\(count)).")
        }
    }
    if rows.isEmpty { return lines.joined(separator: "\n") }
    lines += ["", "| Versicherer | Vertragsnummer | Kündigungsfrist | Vertragsbeleg |",
              "| --- | --- | --- | --- |"]
    for row in rows {
        guard let object = row.objectValue, let fields = object["fields"]?.objectValue,
              let proof = object["contractEvidence"]?.objectValue else { throw ChatReportError.invalid }
        let cells = [field(fields["insurer"]), field(fields["policyNumber"]),
                     field(fields["noticePeriod"]), citation(proof)]
        lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
}

func failure(_ reason: String) -> CallTool.Result {
    let messages = [
        "invalid-arguments": "Die Versicherungsrecherche akzeptiert keine Werkzeugparameter.",
        "mcp-denied-or-stale": "Die Freigabe oder der Quellenstand ist nicht mehr gültig. Bitte die Recherche neu starten.",
        "busy": "Eine Recherche läuft bereits.",
        "timeout": "Das Zeitlimit der Recherche wurde erreicht.",
        "cancelled": "Die Recherche wurde abgebrochen.",
        "local-model-unavailable": "Das gewählte lokale Modell ist für die Recherche nicht verfügbar.",
        "call-limit": "Das Limit für Werkzeugaufrufe wurde erreicht.",
        "candidate-limit": "Die Kandidatenmenge überschreitet die Grenze dieses Piloten.",
        "output-limit": "Die Ausgabe überschreitet die Grenze dieses Piloten.",
    ]
    let code = messages[reason] == nil ? "local-service-error" : reason
    let message = messages[code] ?? "Die lokale Recherche konnte nicht abgeschlossen werden."
    let payload: Value? = .object(["status": .string("incomplete"), "reason": .string(code),
                                  "inventoryComplete": .bool(false), "rows": .array([])])
    return .init(content: [.text(text: message + " Es wurden keine Dokumentzeilen ausgegeben.",
                                 annotations: nil, _meta: nil)], structuredContent: payload, isError: true)
}

private enum ChatReportError: Error { case invalid }

private func field(_ value: Value?) -> String {
    guard let object = value?.objectValue else { return "Nicht belegt" }
    switch object["status"]?.stringValue {
    case "evidenced":
        return escape(object["value"]?.stringValue ?? "") + " " + citation(object)
    case "redacted":
        return "Pseudonymisiert " + citation(object)
    case "conflicting":
        let proofs = object["evidence"]?.arrayValue?.compactMap(\.objectValue).map(citation) ?? []
        return "Widersprüchlich " + proofs.joined(separator: ", ")
    default:
        return "Nicht belegt"
    }
}

private func citation(_ proof: [String: Value]) -> String {
    escape(proof["source"]?.stringValue ?? "")
}

private func escape(_ text: String) -> String {
    let markdown = Set("\\\u{60}*_{}[]<>()#+-.!|~")
    return text.split(whereSeparator: \.isNewline).joined(separator: " ").map {
        markdown.contains($0) ? "\\" + String($0) : String($0)
    }.joined()
}
