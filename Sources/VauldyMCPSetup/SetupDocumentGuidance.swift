import Foundation
import VauldyCore

/// Presentation only. Review flags never imply a missing import or start OCR.
struct SetupDocumentGuidance {
    let textStatus: String
    let nextStep: String?
    let needsTextReview: Bool
    let analysisExplanation: String

    init(_ document: VaultDocument) {
        self.init(metadata: document.localImport,
                  hasText: VaultPageMarkedText.sections(in: document.ocrText).contains {
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }, analysisStatus: document.baseAnalysisStatus)
    }

    init(metadata: LocalImportMetadata?, hasText: Bool, analysisStatus: String) {
        let pending = metadata?.state == .queued || metadata?.state == .recognizing
        needsTextReview = !pending && (metadata.map {
            [.partial, .failed, .interrupted, .cancelled].contains($0.state)
                || $0.pages.contains { $0.needsReview || $0.method == .unreadable || $0.metrics?.lineReview?.needsReview == true }
        } ?? !hasText)
        let analysisReason: String
        switch analysisStatus {
        case "completed": analysisReason = "Die Basisanalyse leitet Angaben regelbasiert aus dem gespeicherten Text ab."
        case "needsReview": analysisReason = "Einige Basisangaben sind unklar oder nicht belegt."
        case "failed": analysisReason = "Die Basisanalyse konnte nicht abgeschlossen werden."
        case "stale": analysisReason = "Die Basisanalyse passt nicht mehr zum aktuellen gespeicherten Text."
        case "unavailable": analysisReason = "Es ist keine auswertbare Basisanalyse verfügbar."
        default: analysisReason = "Es liegt noch keine belegte Basisanalyse vor."
        }
        analysisExplanation = analysisReason + " Fehlende Basisangaben allein erfordern weder einen neuen Import noch eine erneute Texterkennung. Prüfe die benötigte Angabe im Original oder über eine konkrete Chatfrage."

        if metadata?.originalState == .changed {
            textStatus = "Original verändert · gespeicherter Text ist historisch"
            nextStep = "Prüfe, welche Originalfassung verwendet werden soll. Ein erneuter Import ist keine Reparatur des bestehenden Originalverweises."
        } else if metadata?.originalState == .unavailable {
            textStatus = "Original nicht erreichbar · gespeicherter Text bleibt erhalten"
            nextStep = "Prüfe den Originalzugriff. Das Dokument ist bereits im Bestand und muss dafür nicht noch einmal hinzugefügt werden."
        } else if pending {
            textStatus = metadata?.state == .queued ? "Texterkennung ausstehend" : "Texterkennung läuft"
            nextStep = "Das Dokument ist im Bestand. Warte auf die Verarbeitung; nicht noch einmal hinzufügen."
        } else if needsTextReview {
            textStatus = hasText ? "Text vorhanden · Prüfhinweise" : "Noch kein lesbarer Text"
            nextStep = hasText
                ? "Vergleiche Original und Text über „Prüfstellen ansehen“. Nur bei fehlendem oder fehlerhaftem Text erneut lesen; kein erneuter Import nötig."
                : "Prüfe das gespeicherte Original. Wenn es lesbar und erreichbar ist, kannst du „Text erneut lesen“ verwenden; kein erneuter Import nötig."
        } else {
            textStatus = hasText ? "Text vorhanden" : "Kein Text erkannt"
            nextStep = hasText ? nil : "Das Dokument ist im Bestand. Prüfe, ob das Original Text enthält."
        }
    }
}
