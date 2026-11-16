import Foundation
import Testing
import VauldyCore
import VauldyDocumentIntelligence
@testable import VauldyMCPSetup

@Suite("Document names in the setup list")
struct SetupDocumentNameTests {
    @Test func neutralGeneratedTitleShowsLabeledFilenameFallback() {
        let document = VaultDocument(title: DocumentTitlePolicy.fallback,
                                     sourceName: "Passender Dokumenttitel.pdf")
        #expect(SetupDocumentName.usesFilename(document))
        #expect(SetupDocumentName.display(document) == "Passender Dokumenttitel")
    }

    @Test func confirmedAndManuallyChosenTitlesRemainVisible() {
        let automatic = VaultDocument(title: "Versicherungsschein – Beispiel GmbH",
                                      sourceName: "Scan_001.pdf")
        #expect(!SetupDocumentName.usesFilename(automatic))
        #expect(SetupDocumentName.display(automatic) == automatic.title)

        var manual = VaultDocument(title: DocumentTitlePolicy.fallback,
                                   sourceName: "Scan_002.pdf")
        manual.setManualTitle("Eigene Bezeichnung")
        #expect(!SetupDocumentName.usesFilename(manual))
        #expect(SetupDocumentName.display(manual) == "Eigene Bezeichnung")
    }
}
