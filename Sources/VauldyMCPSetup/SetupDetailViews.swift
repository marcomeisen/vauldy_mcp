import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

struct SetupDocumentsView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupDocumentSource(model: model)
            DisclosureGroup(isExpanded: $model.editingDocumentGrants) {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.connections.isEmpty {
                        Picker("Verbindung", selection: Binding(get: { model.activeConnectionID }, set: { id in
                            if let profile = model.connections.first(where: { $0.connectionID == id }) { model.edit(profile) }
                        })) {
                            ForEach(model.connections, id: \.connectionID) { Text($0.connectionName).tag(Optional($0.connectionID)) }
                        }.frame(maxWidth: 420).disabled(model.busy || model.importing)
                    }
                    Text("Die Häkchen in der Liste bearbeiten jetzt die Dokumentauswahl für diese Verbindung.")
                        .font(.callout).foregroundStyle(.secondary)
                    SetupDocumentSelectionActions(model: model)
                    if let profile = model.editing {
                        if model.selectionExpandsAccess {
                            Toggle("Ich erlaube die Weitergabe der zusätzlich ausgewählten Dokumentinhalte an diesen Chatbot und gegebenenfalls seinen Cloud-Anbieter.", isOn: $model.acknowledged)
                        }
                        HStack {
                            Button("Freigabeauswahl speichern", action: model.saveSelection).buttonStyle(.borderedProminent)
                                .disabled(!model.selectionChanged || (model.selectionExpandsAccess && !model.acknowledged) || model.busy || model.importing)
                            Button("Gespeicherte Auswahl laden") { if let current = model.activeConnection { model.edit(current) } }
                            Text(profile.enabled ? "Zugriff aktiv" : "Zugriff pausiert").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Richte eine Verbindung ein, um Dokumente für einen Chatbot freizugeben.").foregroundStyle(.secondary)
                    }
                    Button("Bestand abgleichen und Freigabe prüfen …", action: model.startInventoryWorkflow).disabled(model.busy || model.importing)
                }.padding(.top, 10)
            } label: {
                HStack {
                    Label("Chatbot-Freigaben", systemImage: "lock.shield")
                    Spacer()
                    if model.selectionChanged { Text("Ungespeicherte Auswahl").foregroundStyle(.orange) }
                    else { Text("\(model.activeConnection?.allowedDocumentIDs.count ?? 0) freigegeben").foregroundStyle(.secondary) }
                }
            }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .disabled(model.importing)
                .onChange(of: model.editingDocumentGrants) { _, expanded in
                    if expanded, !model.busy, !model.importing, let profile = model.activeConnection,
                       model.editing?.connectionID != profile.connectionID { model.edit(profile) }
                }
            SetupDocumentList(model: model, showsSelectionActions: false)
        }
    }
}

struct SetupDocumentSelectionActions: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let visible = model.visibleSelectableDocumentIDs
        let all = model.selectableDocumentIDs
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(visible.count == 1 ? "1 sichtbares Dokument auswählen" : "\(visible.count) sichtbare Dokumente auswählen") {
                    model.selectDocuments(visible)
                }.disabled(visible.isSubset(of: model.selected))
                    .help("Wählt die lesbaren Treffer der aktuellen Suche und Filter aus.")
                Button("Gesamten Bestand auswählen") { model.selectDocuments(all) }
                    .disabled(all.isSubset(of: model.selected))
                    .help("Wählt alle \(all.count) lesbaren Dokumente aus, einschließlich ausgeblendeter Treffer.")
                Button("Auswahl aufheben", action: model.clearDocumentSelection).disabled(model.selected.isEmpty)
            }
            Text("\(model.selectedReadableCount) ausgewählt · \(SetupText.documents(all.count)) lesbar")
                .font(.callout).foregroundStyle(.secondary)
            if model.documents.contains(where: { !$0.isSearchable }) {
                Text("Dokumente ohne durchsuchbaren Text werden nicht neu ausgewählt. Du kannst ihre Texterkennung erneut starten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy || model.importing || (model.editing == nil && !model.showingSetup))
    }
}

struct SetupDocumentSource: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Neue Dateien hinzufügen …", systemImage: "square.and.arrow.down", action: model.chooseImports)
                Button("Ordner einmal importieren …", systemImage: "folder", action: model.chooseFolderImport)
                Menu("Weitere Quellen") {
                    Button("Lokalen MCP-Bestand laden", action: model.openLocalStore)
                    Button("Beispieldokument ausprobieren", action: model.useExample)
                    Divider()
                    Button("Archivdatei auswählen …", action: model.chooseVault)
                }.fixedSize()
            }
            Text("Einzeldateien werden lokal kopiert. Beim Ordnerimport bleiben die Originale an ihrem Ort.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy || model.importing)
    }
}

struct SetupDocumentList: View {
    static let scrollAnchor = "document-review-list"
    @ObservedObject var model: SetupModel
    var showsSelectionActions = true
    @State private var reviewSelection: ReviewSelection?
    private struct ReviewSelection: Identifiable { let id: UUID }
    private func analysisLabel(_ status: String) -> String {
        switch status {
        case "completed": "Basisanalyse vorhanden (regelbasiert)"
        case "needsReview": "Basisanalyse: prüfen"
        case "failed": "Basisanalyse fehlgeschlagen"
        case "unavailable": "Basisanalyse nicht verfügbar"
        case "stale": "Basisanalyse veraltet"
        default: "Basisanalyse noch nicht erfolgt"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.documents.isEmpty {
                Text("Diese Dokumente sind bereits im Bestand. Prüfhinweise zu Text oder Basisangaben erfordern keinen erneuten Import.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("existing-document-guidance")
            }
            if showsSelectionActions { SetupDocumentSelectionActions(model: model) }
            if let imported = model.shownImportDocumentIDs {
                HStack {
                    Text("Importauswahl · \(SetupText.documents(imported.count))").font(.callout.weight(.medium))
                    Button("Alle Dokumente wieder anzeigen") { model.shownImportDocumentIDs = nil }
                }
            }
            HStack {
                TextField("Dokumente suchen", text: $model.documentSearch).textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $model.documentFilter) {
                    ForEach(SetupDocumentFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 220)
            }
            if !model.showingSetup && !model.editingDocumentGrants && model.isLocalVault {
                HStack {
                    Button("Treffer auswählen (\(model.visibleOCRDocumentIDs.count))") { model.ocrSelected.formUnion(model.visibleOCRDocumentIDs) }
                        .disabled(model.visibleOCRDocumentIDs.isSubset(of: model.ocrSelected))
                        .help("Wählt alle Treffer der aktuellen Suche und Filter für OCR aus, auch unterhalb des sichtbaren Fensterausschnitts.")
                    Button("Auswahl aufheben") { model.ocrSelected.removeAll() }.disabled(model.ocrSelected.isEmpty)
                    Spacer()
                    Text("\(model.selectedOCRDocuments.count) für OCR ausgewählt").font(.callout).foregroundStyle(.secondary)
                    Button("Ausgewählten Text erneut lesen", systemImage: "arrow.clockwise", action: model.retrySelectedOCR)
                        .disabled(model.selectedOCRDocuments.isEmpty)
                        .help("Optional bei fehlendem oder fehlerhaftem Text. Ein Hinweis zur Basisanalyse allein erfordert keinen neuen Textlauf.")
                        .accessibilityIdentifier("batch-ocr-start")
                }.disabled(model.busy || model.importing)
                let visibleIDs = Set(model.filteredDocuments.map(\.id))
                let hidden = model.ocrSelected.subtracting(visibleIDs).count
                Text(hidden > 0 ? "\(hidden) ausgewählte Dokumente außerhalb des Filters werden ebenfalls gelesen." : "Erneut lesen ist optional und fügt keine Dokumente hinzu. Bestehende Belegzeilen und Chatbot-Freigaben bleiben erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.filteredDocuments.isEmpty {
                ContentUnavailableView(model.documents.isEmpty ? "Noch keine Dokumente" : "Keine passenden Dokumente", systemImage: "doc.text.magnifyingglass", description: Text(model.documents.isEmpty ? "Importiere PDFs oder Bilder oder probiere das Beispieldokument aus." : "Ändere Suche oder Filter."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredDocuments, id: \.id) { document in
                        HStack(alignment: .top, spacing: 12) {
                            let ocrMode = !model.showingSetup && !model.editingDocumentGrants
                            Toggle(isOn: Binding(get: { ocrMode ? model.ocrSelected.contains(document.id) : model.selected.contains(document.id) }, set: { value in
                                if ocrMode {
                                    if value { model.ocrSelected.insert(document.id) } else { model.ocrSelected.remove(document.id) }
                                } else { model.setDocumentSelected(value, id: document.id) }
                            })) { Text("\(model.documentDisplayName(document)) \(ocrMode ? "für OCR" : "für Chatbot") auswählen") }.labelsHidden()
                                .disabled(model.busy || model.importing || (ocrMode ? (!model.canRetryOCR(document) && !model.ocrSelected.contains(document.id)) : ((!document.isSearchable && !model.selected.contains(document.id)) || (model.editing == nil && !model.showingSetup))))
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.documentDisplayName(document)).font(.body.weight(.medium)).help(document.sourceName)
                                HStack(spacing: 10) {
                                    Text("Im Bestand")
                                    Text(model.importLabel(document, compact: true))
                                    Text(analysisLabel(document.baseAnalysisStatus))
                                }.font(.caption).foregroundStyle(.secondary)
                                if let step = SetupDocumentGuidance(document).nextStep {
                                    Text(step).font(.caption).foregroundStyle(.secondary)
                                }
                                if let metadata = document.localImport {
                                    Text((document.pageCount.map { SetupText.pages($0) } ?? "Seitenzahl offen") + " · " + (metadata.originalReference == nil ? "Lokale Kopie" : "Originalverweis"))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                Text(SetupText.importTimestamp(document.importedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .help("Zeitpunkt des Imports in diesen Bestand, angezeigt in der lokalen Mac-Zeitzone. Kein Dokumentdatum und kein Zeitpunkt eines späteren OCR-Laufs.")
                                    .accessibilityIdentifier("document-import-timestamp")
                                SetupDocumentAnalysisView(document: document)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if model.isLocalVault {
                                Button("Original öffnen") { model.preview(document) }
                                if let state = document.localImport?.state, ![.queued, .recognizing].contains(state) {
                                    Button("Text prüfen") { reviewSelection = .init(id: document.id) }
                                        .help("Vergleicht Original und gespeicherten Text. Startet keine Texterkennung.")
                                        .accessibilityIdentifier("document-text-review")
                                }
                            }
                        }.padding(14)
                        Divider()
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }.id(Self.scrollAnchor)
            .sheet(item: $reviewSelection) { item in
                SetupQualityReviewView(model: model, documentID: item.id, reportID: nil)
            }
    }
}

struct SetupFoldersView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Einmaliger Import").font(.headline)
                Button("Ordner einmal importieren …", action: model.chooseFolderImport)
                Text("Vauldy durchsucht die gewählten Ordner einmal und verknüpft die Originale.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.importing)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatische Ordnerüberwachung").font(.headline)
                HStack {
                    Button("Ordner zur Überwachung hinzufügen …", systemImage: "folder.badge.plus", action: model.chooseWatchedFolders)
                    Toggle("Unterordner einbeziehen", isOn: $model.watchRecursive).help("Gilt für neu hinzugefügte Ordner.")
                }
            }.disabled(model.busy || model.importing)
            Text("Ordnerimporte verwenden deine Originaldateien über dauerhafte Dateiverweise. Verschobene, gelöschte oder geänderte Originale können einen erneuten Zugriff erfordern. Neue Dokumente bleiben bis zu deiner ausdrücklichen Freigabe für Chatbots gesperrt.").foregroundStyle(.secondary)
            HStack {
                Button("Bestehende Kopien prüfen …", action: model.inspectOriginalMigration)
                Button("Originalzugriff prüfen", action: model.checkOriginals)
            }.disabled(model.busy || model.importing)
            if model.watchedFolders.isEmpty { ContentUnavailableView("Noch keine beobachteten Ordner", systemImage: "folder", description: Text("Du kannst einen oder mehrere Ordner hinzufügen.")) }
            ForEach(model.watchedFolders, id: \.id) { folder in
                VStack(alignment: .leading, spacing: 12) {
                    Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder").font(.headline)
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text(model.watchLabel(folder)).font(.callout)
                        Spacer()
                        Button(folder.enabled ? "Pausieren" : "Fortsetzen") { model.changeWatchedFolder(folder) }
                        Button("Entfernen", role: .destructive) { model.changeWatchedFolder(folder, remove: true) }
                    }
                    Text(folder.recursive ? "Mit Unterordnern" : "Ohne Unterordner").font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            if !model.watchFailure.isEmpty { SetupNotice(text: model.watchFailure, warning: true) }
            if model.watchedFolders.contains(where: \.enabled) && !model.watchRunning {
                Button("Ordnerüberwachung starten") { Task { await model.refreshWatchedFolders(resume: true) } }
            }
            Text("Beim Pausieren werden bereits gestartete Importe abgeschlossen. Entfernen eines Ordners löscht keine importierten Dokumente.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SetupSettingsView: View {
    @ObservedObject var model: SetupModel
    @State private var confirmRollback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Software auf diesem Mac").font(.headline)
                    LabeledContent("Diese App", value: MCPBuild.version)
                    LabeledContent("App-Build", value: MCPBuildIdentity.running ?? "Unbekannt")
                    LabeledContent("Mitgelieferter Server-Build", value: model.software?.availableBuildID ?? "Noch nicht geprüft")
                    LabeledContent("Installierter Server-Build", value: model.software?.installedBuildID ?? "Unbekannt / älteres Paket")
                    LabeledContent("Eigener Dokumentspeicher", value: model.localStore.storageKind == "sqlite" ? "Lokale SQLite-Datenbank" : "Lokaler JSON-Bestand")
                    LabeledContent("Installierter Server", value: model.software?.installedVersion ?? "Noch nicht verifiziert")
                    Text(model.software?.state == .current ? "Die installierten Programme entsprechen dieser App." : "Installiere die Programme aus dieser App. Freigaben, pausierte Zugriffe und Client-Einträge bleiben erhalten.").foregroundStyle(.secondary)
                    HStack {
                        if model.software?.state == .notInstalled {
                            Button("Installation starten") { model.showingInstallation = true }.disabled(model.busy)
                        } else {
                            Button("Software aktualisieren", action: model.updateSoftware)
                                .disabled(model.busy || model.software?.state != .updateAvailable)
                        }
                        if model.software?.canRollback == true {
                            Button("Vorversion wiederherstellen") { confirmRollback = true }
                                .disabled(model.busy)
                                .confirmationDialog("Vorherigen Programmsatz aktivieren?", isPresented: $confirmRollback) {
                                    Button("Vorversion aktivieren", action: model.rollbackSoftware)
                                }
                        }
                        Button("Erneut prüfen") { model.software = nil; Task { await model.refreshManagement(checkBindings: true) } }
                    }
                    Text("Bereits laufende Server verwenden ihre bisherige Version bis zum nächsten Start durch den Chatbot.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Statusmenü").font(.headline)
                    Text("Verbindungen, Dokumentzugriff und Ordnerüberwachung direkt in der Menüleiste prüfen und verwalten.").foregroundStyle(.secondary)
                    Button("Statusanzeige öffnen", action: model.showStatusMenu)
                    if !model.statusMenuFailure.isEmpty { SetupNotice(text: model.statusMenuFailure, warning: true) }
                    Text("„Statusanzeige beenden“ schließt nur die Anzeige. Server und Importe laufen weiter.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speicher und Datenschutz").font(.headline)
                    Text("MCP gibt ausschließlich die pro Verbindung ausgewählten Dokumente lesend frei. Dein Chatbot kann angeforderte Inhalte an seinen Anbieter übertragen. Lokale Texterkennung und Originale bleiben in diesem Bestand auf dem Mac.").foregroundStyle(.secondary)
                    Button("Lokalen Vauldy-Ordner öffnen") { NSWorkspace.shared.open(model.installation.root) }
                    DisclosureGroup("Erweiterte Verwaltung") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.installation.root.path).font(.caption).textSelection(.enabled)
                            Button("Importdienst nach laufendem Auftrag beenden", action: model.stopWorker)
                            Text("Damit wird auch die Ordnerüberwachung angehalten. Du kannst sie unter „Ordner“ wieder starten.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SetupDiagnosisView: View {
    @ObservedObject var model: SetupModel
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Verbindung prüfen").font(.title2.weight(.semibold))
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if let profile = model.connections.first(where: { $0.connectionID == profileID }) {
                Text(profile.connectionName).font(.headline)
                Label(model.state(for: profile).serverLabel, systemImage: "network")
                Label(model.state(for: profile).accessLabel, systemImage: "lock.shield")
                Text(model.state(for: profile).explanation).font(.callout)
                ForEach(Array(model.state(for: profile).matchingServers.enumerated()), id: \.offset) { _, instance in
                    Text("Laufender Server: " + (instance.version ?? "Unbekannt") + " · " + (instance.buildID ?? "Build unbekannt")).font(.caption)
                }
                Text("Externe Chatverbindung: Durch diesen Test nicht bestätigt. Bei erfolgreichem lokalen Test die Verbindung und Werkzeugfreigabe im Chatbot prüfen.").foregroundStyle(.secondary)
                Label(model.bindingLabel(profile), systemImage: "link")
                Divider()
                if model.probing.contains(profileID) { ProgressView("Lokaler MCP-Protokolltest läuft …") }
                if let result = model.probeResults[profileID] {
                    Label(result.summary, systemImage: result.compatible ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.compatible ? .green : .orange)
                    LabeledContent("Server", value: result.serverVersion)
                    LabeledContent("Geprüfter Build", value: result.serverBuildID ?? "Unbekannt / älterer Server")
                    Text("Werkzeuge (\(result.discoveredTools.count)): " + result.discoveredTools.joined(separator: ", ")).font(.caption).textSelection(.enabled)
                    Text(result.nextStep).font(.callout)
                    Text("\(SetupText.documents(result.grantedDocuments)) im Test zugänglich · \(result.completedAt.formatted(date: .omitted, time: .standard))").font(.callout)
                }
                if let error = model.probeErrors[profileID] { SetupNotice(text: error, warning: true) }
                Text("Der Test startet einen eigenen lokalen Prüfprozess und liest keine Dokumentinhalte. Er bestätigt keine Verbindung oder Cloud-Anfrage deines Chatbots.").foregroundStyle(.secondary)
                HStack {
                    Button("Erneut testen") { model.checkConnection(profile, present: false) }.disabled(model.probing.contains(profileID))
                    if model.client(for: profile) != nil && model.bindings[profileID] != .registered {
                        Button("Im Chatbot eintragen") { model.reconnect(profile) }.disabled(!profile.enabled)
                    }
                    Button("Konfiguration kopieren") { model.copyConfiguration(for: profile) }
                }
                Text("Wenn ein älterer Server läuft: Starte die Vauldy-Verbindung in der MCP-Verwaltung deines Chatbots neu.").font(.callout).foregroundStyle(.secondary)
            } else { Text("Diese Verbindung ist nicht mehr vorhanden.") }
            }
            }
            HStack { Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 680, height: 640)
    }
}
