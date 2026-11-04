import AppKit
import SwiftUI
import VauldyCore
import VauldyMCPRuntime

struct SetupDocumentsView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.connections.isEmpty {
                Picker("Auswahl für", selection: Binding(get: { model.activeConnectionID }, set: { id in
                    if let profile = model.connections.first(where: { $0.connectionID == id }) { model.edit(profile) }
                })) {
                    ForEach(model.connections, id: \.connectionID) { Text($0.connectionName).tag(Optional($0.connectionID)) }
                }.frame(maxWidth: 420).disabled(model.busy)
            }
            SetupDocumentSource(model: model)
            SetupDocumentSelectionActions(model: model)
            if let profile = model.editing {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(SetupText.documents(model.selected.count)) für \(profile.connectionName) ausgewählt").font(.headline)
                    if model.selectionExpandsAccess {
                        Toggle("Ich erlaube, dass dieser Chatbot die zusätzlich ausgewählten Dokumentinhalte erhält. Je nach Chatbot können diese an dessen Cloud-Anbieter übertragen werden.", isOn: $model.acknowledged)
                    }
                    HStack {
                        Button("Auswahl speichern", action: model.saveSelection).buttonStyle(.borderedProminent)
                            .disabled(!model.selectionChanged || (model.selectionExpandsAccess && !model.acknowledged) || model.busy)
                        Text(profile.enabled ? "Zugriff bleibt freigegeben." : "Zugriff bleibt pausiert.").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Gespeicherte Auswahl neu laden") { if let current = model.activeConnection { model.edit(current) } }.disabled(model.busy)
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Importe erteilen keine Freigabe. Richte eine Verbindung ein, um Dokumente für einen Chatbot auszuwählen.").foregroundStyle(.secondary)
            }
            Button("Bestand abgleichen und neu freigeben …", action: model.startInventoryWorkflow).disabled(model.busy || model.importing)
            SetupDocumentList(model: model, showsSelectionActions: false)
        }
    }
}

struct SetupDocumentSelectionActions: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Alle auswählen", systemImage: "checkmark.circle", action: model.selectAllDocuments)
                    .disabled(model.selectableDocumentIDs.isEmpty || model.allReadableDocumentsSelected)
                    .help("Markiert den gesamten lesbaren Bestand, auch außerhalb der aktuellen Suche oder des Filters. Suchbegriff und Filter werden zurückgesetzt.")
                Button("Auswahl aufheben", action: model.clearDocumentSelection).disabled(model.selected.isEmpty)
                Spacer()
                Text("\(SetupText.documents(model.selectableDocumentIDs.count)) lesbar").font(.callout).foregroundStyle(.secondary)
            }
            if model.documents.contains(where: { !$0.isSearchable }) {
                Text("Dokumente ohne durchsuchbaren Text werden nicht neu ausgewählt. Du kannst ihre Texterkennung erneut starten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy || (model.editing == nil && !model.showingSetup))
    }
}

struct SetupDocumentSource: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        HStack(spacing: 12) {
            Button("Dokumente importieren", systemImage: "square.and.arrow.down", action: model.chooseImports).disabled(model.importing)
            Menu("Weitere Quellen") {
                Button("Lokalen MCP-Bestand laden", action: model.openLocalStore)
                Button("Beispieldokument ausprobieren", action: model.useExample).disabled(model.importing)
                Divider()
                Button("Archivdatei auswählen …", action: model.chooseVault)
            }.fixedSize()
            Spacer()
            Text("\(model.documents.count) lokal verfügbar").font(.callout).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }
}

struct SetupDocumentList: View {
    @ObservedObject var model: SetupModel
    var showsSelectionActions = true
    private func analysisLabel(_ status: String) -> String {
        switch status {
        case "completed": "Basisanalyse vorhanden (regelbasiert)"
        case "needsReview": "Basisanalyse: prüfen"
        case "failed": "Basisanalyse fehlgeschlagen"
        case "unavailable": "Kein Text für Basisanalyse"
        case "stale": "Basisanalyse veraltet"
        default: "Basisanalyse noch nicht erfolgt"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsSelectionActions { SetupDocumentSelectionActions(model: model) }
            HStack {
                TextField("Dokumente suchen", text: $model.documentSearch).textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $model.documentFilter) {
                    ForEach(SetupDocumentFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 220)
            }
            if model.filteredDocuments.isEmpty {
                ContentUnavailableView(model.documents.isEmpty ? "Noch keine Dokumente" : "Keine passenden Dokumente", systemImage: "doc.text.magnifyingglass", description: Text(model.documents.isEmpty ? "Importiere PDFs oder Bilder oder probiere das Beispieldokument aus." : "Ändere Suche oder Filter."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredDocuments, id: \.id) { document in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(isOn: Binding(get: { model.selected.contains(document.id) }, set: { value in
                                model.setDocumentSelected(value, id: document.id)
                            })) { Text("\(document.title) auswählen") }.labelsHidden()
                                .disabled(model.busy || (!document.isSearchable && !model.selected.contains(document.id)) || (model.editing == nil && !model.showingSetup))
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).font(.body.weight(.medium))
                                Text(analysisLabel(document.baseAnalysisStatus)).font(.caption).foregroundStyle(.secondary)
                                Text(model.importLabel(document).isEmpty ? document.sourceName : model.importLabel(document)).font(.caption).foregroundStyle(.secondary)
                                if let metadata = document.localImport {
                                    Text(metadata.originalReference == nil ? "Lokale Kopie" : "Verweis auf Originaldatei").font(.caption).foregroundStyle(.secondary)
                                }
                                SetupDocumentAnalysisView(document: document)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if model.vaultURL == model.localStore.snapshotURL {
                                Button("Vorschau") { model.preview(document) }
                                if let state = document.localImport?.state, ![.queued, .recognizing].contains(state) {
                                    Button("Text erneut lesen") { model.importFiles([], retry: document.id) }.disabled(model.importing)
                                        .help("Liest das gesicherte Original mit frischer OCR und Basisanalyse. Vorhandene OCR-Cacheeinträge werden nicht verwendet; Freigaben bleiben unverändert.")
                                }
                            }
                        }.padding(14)
                        Divider()
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct SetupFoldersView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Ordner hinzufügen …", systemImage: "folder.badge.plus", action: model.chooseWatchedFolders).buttonStyle(.borderedProminent)
                Toggle("Unterordner einbeziehen", isOn: $model.watchRecursive).help("Gilt für neu hinzugefügte Ordner.")
            }.disabled(model.busy)
            Text("Ordnerimporte verwenden deine Originaldateien über dauerhafte Dateiverweise. Verschobene, gelöschte oder geänderte Originale können einen erneuten Zugriff erfordern. Neue Dokumente bleiben bis zu deiner ausdrücklichen Freigabe für Chatbots gesperrt.").foregroundStyle(.secondary)
            HStack {
                Button("Ordner einmal importieren …", action: model.chooseFolderImport)
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
            if let profile = model.connections.first(where: { $0.connectionID == profileID }) {
                Text(profile.connectionName).font(.headline)
                Label(model.state(for: profile).serverLabel, systemImage: "network")
                Label(model.state(for: profile).accessLabel, systemImage: "lock.shield")
                Label(model.bindingLabel(profile), systemImage: "link")
                Divider()
                if model.probing.contains(profileID) { ProgressView("Lokaler MCP-Protokolltest läuft …") }
                if let result = model.probeResults[profileID] {
                    Label("Lokaler Protokolltest erfolgreich", systemImage: "checkmark.circle").foregroundStyle(.green)
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
            HStack { Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 580)
    }
}
