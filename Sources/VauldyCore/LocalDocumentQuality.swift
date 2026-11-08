import Foundation
import CoreGraphics
import VauldyDocumentIntelligence

/// Local presentation only. No quality percentage, model approval or inferred missing original pages.
package struct LocalDocumentQuality: Sendable {
    package enum Category: String, CaseIterable, Sendable {
        case source, processing, text, tables, classification, fields, analysis
        package var title: String {
            switch self {
            case .source: "Originalzugriff"
            case .processing: "Seitenverarbeitung"
            case .text: "Texterkennung"
            case .tables: "Tabellen"
            case .classification: "Dokumentart"
            case .fields: "Basisangaben"
            case .analysis: "Basisanalyse"
            }
        }
    }
    package struct Focus: Equatable, Sendable {
        package let page: Int
        package var quote: String? = nil
        package var bounds: [CGRect] = []
    }
    package struct Issue: Identifiable, Sendable {
        package let id: String
        package let category: Category
        package let title: String
        package let detail: String
        package let requiresReview: Bool
        package let focus: Focus?
    }
    package let processedPages: Int
    package let expectedPages: Int?
    package let processingLabel: String
    package let analysisLabel: String
    package let recognitionLabel: String
    package let issues: [Issue]
    package let pending: Bool
    package var reviewCount: Int { issues.filter(\.requiresReview).count }
    package var headline: String {
        if pending { return "Verarbeitung noch nicht abgeschlossen" }
        return reviewCount == 0 ? "Automatische Grundprüfung ohne Befund" : "Prüfung erforderlich · \(reviewCount) \(reviewCount == 1 ? "Hinweis" : "Hinweise")"
    }
    package static let completenessExplanation = "Erfasste PDF-Seiten bestätigen nicht, dass dem Original keine Seiten fehlen."
    package static let manualReviewLabel = "Abschließende Prüfung: nicht dokumentiert"
    package static let tableLabel = "Keine separate Tabellenprüfung vorhanden"

    package init(document: VaultDocument, pages: [LocalDocumentReview.Page]) {
        expectedPages = document.pageCount.flatMap { (1...200).contains($0) ? $0 : nil }
        pending = document.localImport?.state == .queued || document.localImport?.state == .recognizing
        processedPages = pages.filter { $0.info != nil && $0.info?.method != .unreadable && ($0.text != nil || $0.info?.method == .blank) }.count
        if pending {
            processingLabel = document.localImport?.state == .queued ? "Texterkennung ausstehend" : "Texterkennung läuft"
        } else if let expectedPages {
            processingLabel = "\(processedPages) von \(expectedPages) vorhandenen Seiten verarbeitet"
        } else { processingLabel = "\(processedPages) Seiten zugeordnet · Seitenzahl offen" }
        let methods = Set(pages.compactMap { $0.info?.method })
        recognitionLabel = methods.contains(.vision) || methods.contains(.embeddedTextAndVision)
            ? "Apple Vision / vorhandene PDF-Textebene" : methods.contains(.embeddedText) ? "Vorhandene PDF-Textebene" : "Kein Erkennungsverfahren belegt"
        switch document.baseAnalysisStatus {
        case "completed": analysisLabel = "Regelbasierte Basisanalyse vorhanden"
        case "needsReview": analysisLabel = "Basisanalyse mit Prüfhinweisen"
        case "stale": analysisLabel = "Basisanalyse veraltet"
        case "failed": analysisLabel = "Basisanalyse fehlgeschlagen"
        default: analysisLabel = "Keine aktuelle Basisanalyse vorhanden"
        }
        var findings: [Issue] = []
        func add(_ category: Category, _ code: String, _ title: String, _ detail: String,
                 focus: Focus? = nil, review: Bool = true) {
            findings.append(.init(id: "\(category.rawValue)-\(code)-\(focus?.page ?? 0)-\(findings.count)", category: category,
                                 title: title, detail: detail, requiresReview: review, focus: focus))
        }
        if document.localImport?.originalState == .changed {
            add(.source, "changed", "Original verändert", "Gespeicherter Text und Belege gehören zur zuvor gelesenen Fassung. Aktuelle Stellenmarkierungen bleiben ausgeblendet.")
        } else if document.localImport?.originalState != .available {
            add(.source, "unverified", "Originalzugriff nicht bestätigt", "Gespeicherter Text bleibt erhalten. Prüfe den Zugriff, bevor du ihn mit dem Original vergleichst.")
        }
        if !pending {
            if expectedPages == nil { add(.processing, "unknown", "Seitenumfang nicht belegt", "Die Zahl der vorhandenen Originalseiten ist nicht zuverlässig gespeichert.") }
            if let state = document.localImport?.state, state != .completed, document.localImport?.error == nil {
                add(.processing, "unfinished", "Textlauf nicht vollständig abgeschlossen", "Die Verarbeitung wurde nur teilweise abgeschlossen, unterbrochen oder abgebrochen. Bereits gespeicherter Text bleibt erhalten.")
            }
            if let expectedPages, document.localImport?.pages.contains(where: { !(1...expectedPages).contains($0.page) }) == true {
                add(.processing, "range", "Gespeicherte Seitenzuordnung widersprüchlich", "Verarbeitungsdaten liegen außerhalb des gespeicherten Seitenumfangs. Daraus lässt sich keine vollständige Verarbeitung ableiten.")
            }
            if let error = document.localImport?.error {
                add(.processing, "import", "Textlauf nicht vollständig abgeschlossen", error.errorDescription ?? "Prüfe das gespeicherte Original.")
            }
            for page in pages {
                let focus = Focus(page: page.id)
                if page.info?.method == .unreadable {
                    add(.text, "unreadable", "Kein lesbarer Text erkannt", "Vergleiche Seite \(page.id) mit dem Original. Eine unlesbare Erkennung ist keine fehlende Seite.", focus: focus)
                } else if page.info == nil || page.text == nil && page.info?.method != .blank {
                    add(.processing, "unassigned", "Seitentext nicht eindeutig zugeordnet", "Für Seite \(page.id) fehlt eine eindeutige gespeicherte Verarbeitung. Das belegt keine fehlende Originalseite.", focus: focus)
                }
                if let lines = page.info?.metrics?.lineReview {
                    if lines.unconfirmedLines > 0 { add(.text, "uncertain", "\(lines.unconfirmedLines) unbestätigte Zeilen", "Die unsicheren Zeilen sind nicht durch passende Lesungen bestätigt. Gespeichert ist ein Seitenhinweis, keine genaue Zeilenposition.", focus: focus) }
                    if lines.ambiguousIdentifiers > 0 { add(.text, "identifier", "Mehrdeutige Kennungen", "Buchstaben und Ziffern lassen sich nicht eindeutig unterscheiden. Prüfe die Kennungen auf dieser Seite am Original.", focus: focus) }
                    if lines.conflictingReadings > 0 { add(.text, "conflict", "Widersprüchliche Lesungen", "Die Lesungen stimmen nicht überein; bisherige Werte wurden erhalten. Eine genaue Konfliktposition ist nicht gespeichert.", focus: focus) }
                    if lines.budgetLimitedLines > 0 || lines.unavailableRetries > 0 { add(.text, "retry", "Nachlese nicht abgeschlossen", "Das lokale Nachlesebudget oder eine nicht verfügbare Wiederholung lässt unsichere Zeilen offen.", focus: focus) }
                    if lines.lowConfidenceRegions > 0 || lines.shortTextRegions > 0 { add(.text, "weak", "Auffällige Texterkennung", "Die Erkennung meldet schwache Zeilenkonfidenz oder sehr wenig Text. Das ist keine prozentuale Qualitätsbewertung des Dokuments.", focus: focus) }
                }
                if page.info?.metrics?.evidencePreservedFallback == true { add(.text, "retained", "Bisheriger Text erhalten", "Ein neuer Lauf hätte belegten Text verändert oder verloren. Prüfe die erhaltene Fassung am Original.", focus: focus) }
                if let coverage = page.layout?.geometry.coverage {
                    for (index, region) in coverage.regions.enumerated() where region.needsReview {
                        add(.text, "region-\(index)", "Möglicherweise nicht erfasster Textbereich", "Die markierte Bildregion enthält visuelle Zeichen ohne ausreichende Textzuordnung. Das beweist keine vollständige Auslassung.", focus: .init(page: page.id, bounds: [region.bounds]))
                    }
                    if coverage.status != .checked { add(.text, "coverage", "Visuelle Textabdeckung offen", "Der zusätzliche Vergleich von Bildregionen und erfasstem Text ist eingeschränkt oder nicht verfügbar.", focus: focus) }
                }
                if page.needsReview && !findings.contains(where: { $0.focus?.page == page.id }) {
                    add(.text, "legacy", "Gespeicherter Prüfhinweis", "Für diese Seite liegt kein genauerer Prüfgrund vor. Vergleiche Original und Text.", focus: focus)
                }
            }
        }
        if let analysis = document.currentBaseAnalysis {
            for card in analysis.documents {
                let focus = card.pages.first.flatMap { n in pages.contains(where: { $0.id == n }) ? Focus(page: n) : nil }
                if card.kind == .unknown { add(.classification, "unknown", "Dokumentart unklar", "Die lokale Basisanalyse kann diesen Dokumentbereich keiner belegten Art zuordnen.", focus: focus) }
                for (role, value) in [("Aussteller", card.issuer), ("Dokumentdatum", card.issueDate), ("Gegenstand", card.subject), ("Übersicht", card.overview)] where value == nil {
                    add(.fields, role, "\(role) nicht belegt", "Die Basisanalyse hat diese Angabe nicht belegt. Prüfe sie bei Bedarf im Original. Daraus folgt nicht, dass die Angabe im Dokument fehlt oder eine Pflichtangabe verletzt ist.", focus: focus, review: role == "Gegenstand" || role == "Übersicht")
                }
                for code in card.issues where !["DOCUMENT_TYPE_UNRESOLVED", "SUBJECT_UNRESOLVED", "OVERVIEW_UNAVAILABLE"].contains(code) {
                    let roles: [(String, String)] = [("DOCUMENTTYPE", "Dokumentart"), ("ISSUER", "Aussteller"), ("RECIPIENT", "Empfänger"), ("ISSUEDATE", "Dokumentdatum"), ("SUBJECT", "Gegenstand"), ("TITLEYEAR", "Bezugsjahr"), ("OVERVIEW", "Übersicht")]
                    if let role = roles.first(where: { code == "UNSUPPORTED_" + $0.0 || code == "CONFLICTING_" + $0.0 }) {
                        add(.fields, code, "\(role.1): \(code.hasPrefix("CONFLICTING_") ? "widersprüchliche Angaben" : "Quellbeleg fehlt")", "Die Angabe ist nicht eindeutig durch Text auf der zugehörigen physischen Seite belegt. Ein abgewiesener Vorschlag gilt nicht als bestätigter Wert.", focus: focus)
                    } else if code == "DOCUMENT_DATE_UNRESOLVED" {
                        add(.fields, code, "Dokumentdatum unklar", "Die Rolle oder der Wert des Datums lässt sich nicht eindeutig belegen.", focus: focus)
                    } else if code == "UNTRUSTED_INSTRUCTION_TEXT" {
                        add(.analysis, code, "Anweisungsförmiger Quelltext", "Der Text enthält möglicherweise Anweisungen. Dokumentinhalt wird nicht als Arbeitsauftrag übernommen.", focus: focus)
                    } else {
                        add(.analysis, code, "Dokumentzuordnung oder Angaben unklar", "Die Basisanalyse kann diesen Dokumentbereich nicht abschließend zuordnen. Prüfe die zugehörigen Seiten und Basisangaben.", focus: focus)
                    }
                }
            }
            if analysis.documents.count > 1 { add(.classification, "multiple", "Mehrere Dokumentbereiche erkannt", "Die Zusammengehörigkeit dieser Bereiche ist nicht fachlich bestätigt.") }
        }
        if document.baseAnalysisStatus != "completed" && !findings.contains(where: { [.analysis, .classification, .fields].contains($0.category) && $0.requiresReview }) {
            add(.analysis, "status", analysisLabel, "Fehlende oder veraltete Basisangaben erfordern allein keinen neuen Import und keinen erneuten Textlauf.", review: !pending)
        }
        issues = findings
    }
}
