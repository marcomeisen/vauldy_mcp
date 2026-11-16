import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

struct SetupDocumentsView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupDocumentSource(model: model)
            if !model.connections.isEmpty { SetupConnectionPicker(model: model) }
            HStack {
                if let profile = model.activeConnection,
                   model.vaultURL == LocalDocumentStore.resolvedSnapshotURL(URL(fileURLWithPath: profile.vaultPath)) {
                    Text("\(SetupText.documents(profile.allowedDocumentIDs.count)) für \(profile.connectionName) freigegeben")
                    Spacer()
                    Button("Freigabe bearbeiten") { model.startInventoryWorkflow(profile: profile) }
                } else {
                    Button("Chatbot verbinden", action: model.newConnection)
                }
            }.disabled(model.busy || model.importing)
            SetupDocumentList(model: model)
        }
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
                    Button("Anderen lokalen Dokumentbestand laden", action: model.openLocalStore)
                    Button("Beispieldokument ausprobieren", action: model.useExample)
                    Divider()
                    Button("Archivdatei auswählen …", action: model.chooseVault)
                }.fixedSize()
            }
            HStack {
                Button("Automatischer Ordnerimport …", systemImage: "folder.badge.plus") { model.section = .folders }
                if model.watchedFolders.contains(where: model.watchNeedsAccess) {
                    Text("Ordner zuletzt nicht erreichbar")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.watchedFolders.contains(where: \.enabled) && model.watchRunning {
                    Text("Ordnerüberwachung aktiv").font(.caption).foregroundStyle(.secondary)
                }
                if model.watchedFolders.contains(where: \.enabled) && !model.watchRunning {
                    Text("Ordnerüberwachung angehalten").font(.caption).foregroundStyle(.secondary)
                    Button("Überwachung starten") { Task { await model.refreshWatchedFolders(resume: true) } }
                }
            }
        }.disabled(model.busy || model.importing)
    }
}

struct SetupDocumentList: View {
    static let scrollAnchor = "document-review-list"
    @ObservedObject var model: SetupModel
    @State private var reviewSelection: ReviewSelection?
    private struct ReviewSelection: Identifiable { let id: UUID; var page: Int? = nil; var quote: String? = nil; var focus: LocalDocumentQuality.Focus? = nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(SetupText.documents(model.documents.count)) " + (model.isLocalVault ? "im lokalen Bestand" : "im ausgewählten Archiv"),
                  systemImage: "tray.full")
                .font(.headline)
                .accessibilityIdentifier("document-inventory-total")

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
            if !model.showingSetup && model.isLocalVault {
                DisclosureGroup("Text erneut lesen", isExpanded: $model.showOCROptions) {
                    HStack {
                        Button("Treffer auswählen (\(model.visibleOCRDocumentIDs.count))") { model.ocrSelected.formUnion(model.visibleOCRDocumentIDs) }
                            .disabled(model.visibleOCRDocumentIDs.isSubset(of: model.ocrSelected))
                            .help("Wählt alle Treffer der aktuellen Suche und Filter zum erneuten Lesen aus, auch unterhalb des sichtbaren Fensterausschnitts.")
                        Button("Auswahl aufheben") { model.ocrSelected.removeAll() }.disabled(model.ocrSelected.isEmpty)
                        Spacer()
                        Text("\(model.selectedOCRDocuments.count) zum erneuten Lesen ausgewählt").font(.callout).foregroundStyle(.secondary)
                        Button("Ausgewählten Text erneut lesen", systemImage: "arrow.clockwise", action: model.retrySelectedOCR)
                            .disabled(model.selectedOCRDocuments.isEmpty)
                            .help("Optional bei fehlendem oder fehlerhaftem Text. Ein Hinweis zur Basisanalyse allein erfordert keinen neuen Textlauf.")
                            .accessibilityIdentifier("batch-ocr-start")
                    }.disabled(model.busy || model.importing)
                    let visibleIDs = Set(model.filteredDocuments.map(\.id))
                    let hidden = model.ocrSelected.subtracting(visibleIDs).count
                    Text(hidden > 0 ? "\(hidden) ausgewählte Dokumente außerhalb des Filters werden ebenfalls gelesen." : "Erneut lesen ist optional und fügt keine Dokumente hinzu. Bestehende Belegzeilen und Chatbot-Freigaben bleiben erhalten.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 4)
            }
            if model.filteredDocuments.count != model.documents.count {
                Text("\(model.filteredDocuments.count) von \(model.documents.count) angezeigt")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.filteredDocuments.isEmpty {
                ContentUnavailableView(model.documents.isEmpty ? "Noch keine Dokumente" : "Keine passenden Dokumente", systemImage: "doc.text.magnifyingglass", description: Text(model.documents.isEmpty ? "Füge PDFs, Bilder oder EML-Dateien hinzu." : "Ändere Suche oder Filter."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredDocuments, id: \.id) { document in
                        HStack(alignment: .top, spacing: 12) {
                            if model.showOCROptions && !model.showingSetup && model.isLocalVault {
                                Toggle("\(model.documentDisplayName(document)) für Texterkennung auswählen", isOn: Binding(get: { model.ocrSelected.contains(document.id) }, set: { value in
                                    if value { model.ocrSelected.insert(document.id) } else { model.ocrSelected.remove(document.id) }
                                })).labelsHidden()
                                    .accessibilityLabel("\(model.documentDisplayName(document)) für Texterkennung auswählen")
                                    .disabled(model.busy || model.importing || (!model.canRetryOCR(document) && !model.ocrSelected.contains(document.id)))
                            }
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.documentDisplayName(document)).font(.body.weight(.medium)).help(document.sourceName)
                                if model.usesFilenameInsteadOfGeneratedTitle(document) {
                                    Text("Dateiname · automatische Überschrift nicht belegt")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Titelangaben") {
                                    Text("Originaldatei: \(document.sourceName)")
                                    if let title = document.generatedTitle { Text("Automatischer Titel: \(title)") }
                                    if let title = document.manualTitle { Text("Eigene Bezeichnung: \(title)") }
                                    if model.isLocalVault {
                                        Button("Titel neu bestimmen") { model.regenerateTitle(document) }
                                            .disabled(model.busy || model.importing || [.queued, .recognizing].contains(document.localImport?.state))
                                            .help("Bestimmt den automatischen Titel aus dem gespeicherten Text. Eigene Titel, Belegzeilen und Chatbot-Freigaben bleiben erhalten.")
                                            .accessibilityIdentifier("document-retitle")
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Text(model.documentSharingLabel(document))
                                    if !model.isLocalVault || document.localImport == nil {
                                        Text(model.importLabel(document, compact: true))
                                    }
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
                                if model.isLocalVault, let review = LocalDocumentReview(document) {
                                    SetupDocumentQualityView(quality: review.quality, documentName: model.documentDisplayName(document)) { focus in
                                        reviewSelection = .init(id: document.id, page: focus.page, quote: focus.quote, focus: focus)
                                    }
                                }
                                SetupDocumentAnalysisView(document: document, openEvidence: model.isLocalVault ? { field in
                                    reviewSelection = .init(id: document.id, page: field.page, quote: field.quote)
                                } : nil)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if model.isLocalVault {
                                Button("Original anzeigen") { model.preview(document) }
                                    .accessibilityLabel("Original von \(model.documentDisplayName(document)) anzeigen")
                                if let state = document.localImport?.state, ![.queued, .recognizing].contains(state) {
                                    Button("Fundstellen ansehen") { reviewSelection = .init(id: document.id) }
                                        .help("Vergleicht Original und gespeicherten Text. Startet keine Texterkennung.")
                                        .accessibilityLabel("Fundstellen für \(model.documentDisplayName(document)) ansehen")
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
                SetupQualityReviewView(model: model, documentID: item.id, reportID: nil, initialPage: item.page, initialQuote: item.quote, initialFocus: item.focus)
            }
    }
}

struct SetupFoldersView: View {
    @ObservedObject var model: SetupModel
    @State private var removeCandidate: LocalWatchedFolder?
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
                    Button("Ordner zur Überwachung hinzufügen …", systemImage: "folder.badge.plus") { model.chooseWatchedFolders() }
                    Toggle("Unterordner einbeziehen", isOn: $model.watchRecursive).help("Gilt für neu hinzugefügte Ordner.")
                }
            }.disabled(model.busy || model.importing)
            Text("PDFs, Bilder und EML-Dateien erscheinen automatisch unter „Dokumente“. Anhänge aus E-Mails werden separat übernommen. Verschobene, gelöschte oder geänderte Originale können einen erneuten Zugriff erfordern. Neue Dokumente bleiben bis zu deiner ausdrücklichen Freigabe für Chatbots gesperrt.").foregroundStyle(.secondary)
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
                        if model.watchNeedsAccess(folder) {
                            Button("Ordner erneut auswählen …") { model.chooseWatchedFolders(reselecting: folder) }
                        }
                        Button(folder.enabled ? "Pausieren" : "Fortsetzen") { model.changeWatchedFolder(folder) }
                        Button("Entfernen", role: .destructive) { removeCandidate = folder }
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
        .confirmationDialog("Ordnerüberwachung entfernen?", isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } }), titleVisibility: .visible) {
            if let folder = removeCandidate {
                Button("Ordner entfernen", role: .destructive) { model.changeWatchedFolder(folder, remove: true); removeCandidate = nil }
            }
            Button("Behalten", role: .cancel) { removeCandidate = nil }
        } message: {
            if let folder = removeCandidate {
                Text("„\(URL(fileURLWithPath: folder.path).lastPathComponent)“ wird nicht mehr überwacht. Bereits importierte Dokumente und Originaldateien bleiben erhalten.")
            }
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
                    LabeledContent("Kennung dieser App", value: MCPBuildIdentity.running ?? "Unbekannt")
                    LabeledContent("Kennung des mitgelieferten Dienstes", value: model.software?.availableBuildID ?? "Noch nicht geprüft")
                    LabeledContent("Kennung des installierten Dienstes", value: model.software?.installedBuildID ?? "Unbekannt / älteres Paket")
                    LabeledContent("Dokumentspeicher", value: model.localStore.storageKind == "sqlite" ? "Lokale Datenbank" : "Lokale Dokumentdatei")
                    LabeledContent("Installierter Server", value: model.software?.installedVersion ?? "Noch nicht verifiziert")
                    Text(model.software?.state == .current ? "Die installierten Programme entsprechen dieser App." : "Installiere die Programme aus dieser App. Freigaben, pausierte Zugriffe und Chatbot-Verbindungen bleiben erhalten.").foregroundStyle(.secondary)
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
                            Text("Damit wird auch die Ordnerüberwachung angehalten. Du kannst sie unter „Dokumente → Automatischer Ordnerimport“ wieder starten.").font(.caption).foregroundStyle(.secondary)
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
