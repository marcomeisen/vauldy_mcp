import Foundation
import Testing
import VauldyMCPRuntime
@testable import VauldyCore
@testable import VauldyMCPSetup

@Suite("Local EML and document counts")
struct LocalEmailTests {
    @Test func alternativeContentDecodesMailHeadersAndPrefersPlainText() throws {
        let email = try LocalEmail(message([
            "From: =?UTF-8?Q?M=C3=BCller?= <mail@example.invalid>",
            "Subject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?=",
            " =?ISO-8859-1?Q?_f=FCr_dich?=",
            "Date: Wed, 11 Nov 2026 12:34:56 +0100",
            "Content-Type: multipart/alternative; boundary=parts",
            "", "--parts", "Content-Type: text/plain; charset=windows-1252",
            "Content-Transfer-Encoding: quoted-printable", "", "Betrag: 5 =80. Zwei=\r\n Zeilen.",
            "--parts", "Content-Type: text/html; charset=utf-8", "", "<p>Nur HTML</p>", "--parts--"
        ]))
        #expect(LocalEmail.title(in: email.text) == "Grüße für dich")
        #expect(email.text.contains("Absender: Müller <mail@example.invalid>"))
        #expect(email.text.contains("Gesendet: Wed, 11 Nov 2026 12:34:56 +0100"))
        #expect(email.text.contains("Betrag: 5 €. Zwei Zeilen."))
        #expect(!email.text.contains("Nur HTML"))
        #expect(!email.needsReview)
    }

    @Test func htmlOnlyUsesVisibleTextAndNeverReadsRemoteImages() throws {
        let email = try LocalEmail(message([
            "Subject: HTML", "Content-Type: text/html; charset=UTF-8", "",
            "<head><title>Keine Belegzeile</title></head><p>Pr&uuml;fung &amp; 10 &#8364;</p>",
            "<script>Problematischer Code</script><img src='https://example.invalid/pixel'>",
            "<p>Weitere Angaben.</p>"
        ]))
        #expect(email.text.contains("Prüfung & 10 €"))
        #expect(email.text.contains("Weitere Angaben."))
        #expect(!email.text.contains("https://"))
        #expect(!email.text.contains("Keine Belegzeile"))
        #expect(!email.text.contains("Problematischer Code"))
    }

    @Test func decodedAttachmentIsNamedLocallyAndDeduplicatedInBothStores() async throws {
        for sqlite in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: dir) }
            let vault = dir.appendingPathComponent("vault")
            let store = try sqlite ? LocalDocumentStore.createSQLite(at: vault) : LocalDocumentStore(root: vault)
            let original = dir.appendingPathComponent("scan.eml")
            let attachment = Data("%PDF-1.7\n%synthetic test".utf8)
            let encoded = attachment.base64EncodedString()
            let attached = ["--test", "Content-Type: application/octet-stream",
                            "Content-Disposition: attachment; filename*0*=UTF-8''..%2FGr%C3%BC; filename*1*=n.pdf",
                            "Content-Transfer-Encoding: base64", "", encoded]
            let data = message(["Subject: Mailprüfung", "Content-Type: multipart/mixed; boundary=test",
                                "", "--test", "Content-Type: text/plain", "", "Gespeicherter Nachrichtentext.",
                                "--- Seite 44 ---"] + attached + attached + ["--test--"])
            try data.write(to: original)
            let first = try await store.stageWithAdditions(file: original, storage: .managedCopy, renewOriginalAccess: false)
            #expect(first.document.title == "Mailprüfung")
            #expect(first.document.isSearchable)
            #expect(first.document.localImport?.state == .completed)
            #expect(first.document.baseAnalysisPages.map(\.number) == [1])
            let childID = try #require(first.document.localImport?.emailAttachmentIDs?.first)
            #expect(Set(first.added) == Set([first.document.id, childID]))
            let child = try #require(try await store.document(id: childID))
            #expect(child.sourceName == "Grün.pdf")
            #expect(child.localImport?.state == .queued)
            #expect(try Data(contentsOf: await store.original(for: childID)) == attachment)
            #expect(try Data(contentsOf: await store.original(for: first.document.id)) == data)
            let saved = try #require(try await store.document(id: first.document.id))
            let duplicate = try await store.stageWithAdditions(file: original, storage: .managedCopy, renewOriginalAccess: false)
            #expect(duplicate.duplicate && duplicate.added.isEmpty && duplicate.document == saved)
            #expect(try await store.documents().count == 2)
            #expect(try await LocalBaseAnalysisService(store: store).regenerateTitle(documentID: first.document.id) == saved)
        }
    }

    @Test func brokenMultipartDoesNotPublishPartialRecords() throws {
        #expect(throws: LocalImportError.invalidDocument) {
            try LocalEmail(message(["Subject: Broken", "Content-Type: multipart/mixed; boundary=end", "",
                                    "--end", "Content-Type: text/plain", "", "Missing final boundary"]))
        }
    }

    @Test func repeatedReadingDoesNotCountAsLocalAdditions() {
        let outcome = LocalImportOutcome(documentID: UUID(), state: .completed, reusedOriginal: false, pageCount: 2)
        var report = SetupImportReport(isRetry: true)
        report.items = [.init(name: "Beispiel", outcome: outcome, isRetry: true)]
        #expect(report.newDocumentIDs.isEmpty)
        #expect(report.summary == "1 mit erneut gelesenem Text")
        var importReport = SetupImportReport(isRetry: false)
        importReport.items = [.init(name: "Beispiel", result: .failed)]
        importReport.addedDocumentIDs = [outcome.documentID]
        #expect(importReport.summary == "1 neu im lokalen Bestand · 1 fehlgeschlagen")
    }

    private func message(_ lines: [String]) -> Data { Data(lines.joined(separator: "\r\n").utf8) }
}
