import SwiftUI
import QuickLook
import VauldyCore
import VauldyMCPRuntime

struct InventoryWorkflowView: View {
    @ObservedObject var model: InventoryWorkflowModel
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: Inspection?
    @State private var confirmClose = false
    @State private var confirmBulkReview = false
    @State private var showCompleteSelection = false
    private var checkingDocuments: Bool { model.busy && model.step == 1 && model.report == nil && !model.committing }
    private struct Inspection: Identifiable { let id: UUID; var focus: LocalDocumentQuality.Focus? = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.step == 0 ? "Originalzugriff wiederherstellen" : "Dokumente freigeben").font(.title2.bold())
                    Text("Chatbot · \(model.profile.connectionName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.completed ? "Fertig" : "Schließen") {
                    if !model.completed && model.selectionChanged { confirmClose = true } else { dismiss() }
                }.disabled(model.busy)
            }
            Divider()
            if checkingDocuments {
                checking
            } else if model.step == 1 && model.report == nil && !model.error.isEmpty {
                checkingFailure
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.completed { completion }
                        else if model.step == 0 { sources }
                        else if model.step == 2 { consent }
                        else if let report = model.report { selection(report) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
            }
            if !model.error.isEmpty && !(model.step == 1 && model.report == nil) {
                SetupNotice(text: model.error, warning: true)
                if !model.busy && !model.completed { Button("Dokumente erneut prüfen", action: model.reportOnly) }
            }
            if model.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(checkingDocuments ? "Deine bisherige Freigabe bleibt unverändert." : model.progress)
                        if let started = model.currentOriginalStartedAt, !model.currentOriginalName.isEmpty {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("\(model.currentOriginalName) · \(max(0, Int(context.date.timeIntervalSince(started)))) s")
                                    .font(.caption)
                            }
                        }
                    }.foregroundStyle(.secondary)
                    Spacer()
                    if !model.committing {
                        Button("Prüfung abbrechen") { model.task?.cancel() }
                    }
                }
            } else if model.step == 1, model.report != nil, !model.completed {
                selectionFooter
            } else if model.step == 2, !model.completed {
                approvalFooter
            }
        }
        .padding(24).frame(minWidth: 700, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .task { await model.loadSources() }
        .sheet(item: $inspection) { item in
            SetupQualityReviewView(store: model.store, executable: model.localExecutable, documentID: item.id,
                initialPage: item.focus?.page, initialFocus: item.focus) { _ in model.reportOnly() }
        }
        .sheet(isPresented: Binding(get: { model.disclosureText != nil }, set: { if !$0 { model.disclosureText = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Das kann der Chatbot lesen").font(.title2.bold())
                Text("Bereinigte Zusammenfassung, Analysefelder und Dokumenttext. Persönliche Sachverhalte können erkennbar bleiben.")
                ScrollView { Text(verbatim: model.disclosureText ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Schließen") { model.disclosureText = nil }
            }.padding().frame(minWidth: 520, minHeight: 380)
        }
        .interactiveDismissDisabled(model.busy || (!model.completed && model.selectionChanged))
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { _, url in if url == nil { model.previewAccess?.close(); model.previewAccess = nil } }
        .confirmationDialog("Ungespeicherte Auswahl verwerfen?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Auswahl verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) { }
        }
        .confirmationDialog("Dokumente mit Prüfhinweisen auswählen?", isPresented: $confirmBulkReview, titleVisibility: .visible) {
            Button("\(model.visibleReviewSelectableIDs.count) Dokumente auswählen", action: model.selectAllVisibleReview)
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Die angezeigten lesbaren Dokumente haben Hinweise zu Text oder Analyse. \(model.visibleReviewKeptLocalCount) davon waren bisher als „Nur lokal behalten“ markiert. Vor der Freigabe musst du die Hinweise und die vollständige Auswahl ausdrücklich bestätigen. Nicht lesbare Dokumente bleiben ausgeschlossen.")
        }
    }

    private var checking: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Wir bereiten deine Auswahl vor", systemImage: "doc.text.magnifyingglass")
                .font(.title3.bold())
            Text("Vauldy lädt die Dokumentauswahl. Die Originale neu ausgewählter Dokumente werden vor dem Speichern geprüft.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.reportPreparing ? "Freigabeübersicht vorbereiten" : "Originalzugriff prüfen")
                    Spacer()
                    if !model.reportPreparing && model.reportCheckTotal > 0 {
                        Text("\(model.reportCheckDone) von \(model.reportCheckTotal) Dokumenten")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !model.reportPreparing && model.reportCheckTotal > 0 {
                    ProgressView(value: Double(model.reportCheckDone), total: Double(model.reportCheckTotal))
                        .accessibilityLabel("Originalzugriff prüfen")
                } else {
                    ProgressView().accessibilityLabel("Dokumente werden geprüft")
                }
                Text("Die Originalprüfung erfolgt erst für die neu ausgewählten Dokumente.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 28)
        .accessibilityIdentifier("grant-checking")
    }

    private var checkingFailure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Prüfung nicht abgeschlossen", systemImage: "exclamationmark.triangle")
                .font(.title3.bold())
            Text(model.error)
            Text("Deine bisherige Freigabe bleibt unverändert.")
                .foregroundStyle(.secondary)
            Button("Erneut prüfen", action: model.reportOnly).buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 28)
    }

    private var selectionFooter: some View {
        HStack(spacing: 12) {
            Text("\(SetupText.documents(model.selected.count)) ausgewählt · \(model.addedCount) neu · \(model.removedCount) entfernt")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Auswahl überprüfen") {
                model.step = 2; model.acknowledged = false; model.acknowledgedReview = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isNewConnection ? model.selected.isEmpty : (!model.selectionChanged && !model.updatesChatGPT))
            .accessibilityIdentifier("grant-review-selection")
        }
    }

    private var approvalFooter: some View {
        HStack(spacing: 12) {
            Button("Auswahl bearbeiten") { model.step = 1 }
            Spacer(minLength: 8)
            Button(model.selected.isEmpty ? "Alle Freigaben entfernen" : "\(SetupText.documents(model.selected.count)) freigeben", action: model.prepareApproval)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.acknowledged || (model.reviewCount > 0 && !model.acknowledgedReview))
                .accessibilityIdentifier("grant-confirm-selection")
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wähle den Ordner, in dem die Originale jetzt liegen. Vauldy vergleicht die Dateien mit den gespeicherten Fassungen.")
            Toggle("Neu gewählte Ordner mit Unterordnern prüfen", isOn: $model.recursive)
            ForEach(model.sources) { folder in
                Toggle(folder.path, isOn: Binding(get: { model.sourceIDs.contains(folder.id) }, set: { value in
                    if value { model.sourceIDs.insert(folder.id) } else { model.sourceIDs.remove(folder.id) }
                    model.plan = nil
                }))
            }
            HStack {
                Button("Originalordner auswählen …", action: model.chooseSources)
                Button("Dateien vergleichen", action: model.inspect).disabled(model.sourceIDs.isEmpty)
            }
            if let plan = model.plan {
                Text("\(plan.files.filter { $0.change == .renewAccess }.count) Originalzugriffe wiederherstellbar · \(plan.files.filter { $0.change == .added }.count) neue Dateien · \(plan.files.filter { $0.change == .changed }.count) neue Fassungen")
                Text("Identische Originale werden wieder zugeordnet. Neue Dateien und Fassungen benötigen anschließend deine Dokumentauswahl.").foregroundStyle(.secondary)
                ForEach(plan.issues) { issue in SetupNotice(text: "\(issue.source) · \(issue.message)", warning: true) }
                Button("Originale zuordnen und neue Dateien einlesen", action: model.importAndReport).buttonStyle(.borderedProminent)
            }
            Button("Zur Dokumentauswahl", action: model.reportOnly)
        }.disabled(model.busy)
    }

    private func selection(_ report: MCPInventoryQualityReport) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Welche Dokumente darf \(model.profile.connectionName) lesen?").font(.headline)
            Text("\(report.rows.count) im Bestand · \(model.profile.allowedDocumentIDs.intersection(Set(report.rows.map(\.id))).count) bereits freigegeben · \(model.newSelectableCount) neu auswählbar · \(model.unavailableNewCount) derzeit nicht auswählbar")
                .font(.callout).foregroundStyle(.secondary)
            if !model.isNewConnection {
                Toggle("Nur noch nicht freigegebene Dokumente", isOn: $model.onlyUnshared)
            }
            TextField("Dokumente suchen", text: $model.search).textFieldStyle(.roundedBorder)
            HStack {
                if !model.visibleNewEligibleIDs.isEmpty {
                    Button("\(model.visibleNewEligibleIDs.count) ohne Prüfhinweise auswählen", action: model.selectAllVisibleEligible)
                        .disabled(model.visibleNewEligibleIDs.isSubset(of: model.selected))
                        .accessibilityIdentifier("grant-select-all-visible")
                }
                if !model.visibleReviewSelectableIDs.isEmpty {
                    Button("\(model.visibleReviewSelectableIDs.count) mit Prüfhinweisen auswählen") { confirmBulkReview = true }
                        .disabled(model.visibleReviewSelectableIDs.isSubset(of: model.selected))
                        .accessibilityIdentifier("grant-select-review-visible")
                }
                Button("Neue Auswahl aufheben", action: model.clearNewSelection)
                    .disabled(model.newlySelectedIDs.isEmpty)
                    .accessibilityIdentifier("grant-clear-new-selection")
                Spacer()
                Text("Geprüft \(report.createdAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Sammelauswahl betrifft nur angezeigte Treffer. Dokumente mit Prüfhinweisen benötigen eine zusätzliche Bestätigung; künftige Importe bleiben ohne Freigabe.")
                .font(.caption).foregroundStyle(.secondary)
            if model.selectedOutsideVisibleRowsCount > 0 {
                SetupNotice(text: "\(model.selectedOutsideVisibleRowsCount) zusätzlich ausgewählte Dokumente liegen außerhalb der aktuellen Suche oder des Filters.", warning: true)
            }
            if model.visibleRows.isEmpty { Text("Keine Dokumente in dieser Ansicht. Ändere die Suche oder zeige alle Dokumente.").foregroundStyle(.secondary) }
            ForEach(model.visibleRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.selected.contains(row.id) }, set: { model.setSelected($0, id: row.id) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                Text(rowStatus(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .accessibilityLabel("\(row.title) für \(model.profile.connectionName) auswählen")
                        .disabled(!row.selectable && !model.selected.contains(row.id) && !model.profile.allowedDocumentIDs.contains(row.id))
                        Spacer(minLength: 0)
                        Menu {
                            Button("Das kann der Chatbot lesen") { model.showDisclosure(row.id) }
                                .disabled(!row.readable)
                            if model.usesLocalStore && (row.original == .unavailable || row.original == .changed) {
                                Button("Originalzugriff wiederherstellen") { model.step = 0 }
                            }
                            if model.usesLocalStore && row.original == .available {
                                Button("Original anzeigen") { model.preview(row.id) }
                            }
                            if !model.isNewConnection && !model.profile.allowedDocumentIDs.contains(row.id) && !model.isKeptLocal(row.id) {
                                Button("Nur lokal behalten") { model.keepLocal(row.id) }
                            }
                            if model.usesLocalStore && row.requiresOriginalVerification {
                                Button("Textprüfung anzeigen") { inspection = .init(id: row.id) }
                            }
                        } label: {
                            Label("Weitere Aktionen", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Weitere Aktionen für \(row.title)")
                    }
                    if model.usesLocalStore && (row.original == .unavailable || row.original == .changed) {
                        Text("Original prüfen oder Zugriff wiederherstellen").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.usesLocalStore && report.selectionReviewIDs.contains(row.id) {
                        Button("Prüfhinweise anzeigen") { inspection = .init(id: row.id) }
                    }
                }.padding(.vertical, 5)
                Divider()
            }
            ForEach(Array(model.selected.subtracting(Set(report.rows.map(\.id)))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                Toggle("Gespeichertes Dokument \(id.uuidString.prefix(8)) · derzeit nicht im Bestand", isOn: Binding(get: { model.selected.contains(id) }, set: { model.setSelected($0, id: id) }))
            }
            ForEach(model.importIssues) { issue in SetupNotice(text: "\(issue.source) · \(issue.message)", warning: true) }
            Button("Dokumente erneut prüfen", action: model.reportOnly)
        }.disabled(model.busy)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Freigabe für \(model.profile.connectionName) bestätigen").font(.headline)
            Text("Danach: \(SetupText.documents(model.selected.count)) freigegeben · \(model.addedCount) neu · \(model.removedCount) entfernt")
                .font(.callout)
            if let report = model.report {
                let changedRows = report.rows.filter { model.selected.contains($0.id) != model.profile.allowedDocumentIDs.contains($0.id) }
                ForEach(Array(changedRows.prefix(3))) { row in
                    Label(row.title, systemImage: model.selected.contains(row.id) ? "plus.circle" : "minus.circle")
                        .lineLimit(1)
                }
                if changedRows.count > 3 || !model.profile.allowedDocumentIDs.subtracting(model.selected).subtracting(Set(report.rows.map(\.id))).isEmpty {
                    DisclosureGroup("Alle Änderungen ansehen") {
                        ForEach(changedRows) { row in
                            Label(row.title, systemImage: model.selected.contains(row.id) ? "plus.circle" : "minus.circle")
                        }
                        ForEach(Array(model.profile.allowedDocumentIDs.subtracting(model.selected).subtracting(Set(report.rows.map(\.id)))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            Label("Gespeichertes Dokument \(id.uuidString.prefix(8)) entfernen", systemImage: "minus.circle")
                        }
                    }
                }
                DisclosureGroup("Gesamte Auswahl prüfen · \(SetupText.documents(model.selected.count))", isExpanded: $showCompleteSelection) {
                    ForEach(report.rows.filter { model.selected.contains($0.id) }) { row in
                        Label(row.title, systemImage: model.profile.allowedDocumentIDs.contains(row.id) ? "checkmark.circle" : "plus.circle")
                    }
                    ForEach(Array(model.selected.subtracting(Set(report.rows.map(\.id)))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        Label("Gespeichertes Dokument \(id.uuidString.prefix(8)) · derzeit nicht im Bestand", systemImage: "exclamationmark.circle")
                    }
                }.accessibilityIdentifier("grant-complete-selection")
            }
            let localRows = model.report?.rows.filter { !model.selected.contains($0.id) } ?? []
            if !localRows.isEmpty {
                Text("\(SetupText.documents(localRows.count)) bleiben für diese Verbindung lokal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("Angeforderte Inhalte werden auf diesem Mac zum Schutz persönlicher Daten aufbereitet und an diesen Chatbot und gegebenenfalls seinen Cloud-Anbieter übertragen. Die Originaldateien bleiben auf deinem Mac.")
                .font(.callout)
            if !model.profile.enabled && !model.isNewConnection { SetupNotice(text: "Der Dokumentzugriff ist pausiert. Die neue Auswahl wird für später gespeichert.", warning: true) }
            if model.selected.isEmpty { SetupNotice(text: "Du entfernst alle Dokumente aus der Freigabe. Dadurch wird der Dokumentzugriff pausiert.", warning: true) }
            if model.reviewCount > 0 {
                Toggle("Ich erlaube die Nutzung der ausgewählten Dokumente mit Hinweisen zu Text, Original oder optionalen Basisangaben (\(model.reviewCount)) unter den angegebenen Einschränkungen.", isOn: $model.acknowledgedReview)
            }
            Toggle("Ich erlaube diesem Chatbot den Zugriff auf die angezeigte Dokumentauswahl.", isOn: $model.acknowledged)
        }.disabled(model.busy)
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Freigabe gespeichert", systemImage: "checkmark.circle.fill").font(.title3)
            Text("\(SetupText.documents(model.selected.count)) für \(model.profile.connectionName) ausgewählt.")
            if model.isNewConnection {
                Text("Schließe dieses Fenster, um die Einrichtung der Verbindung fortzusetzen.")
            } else if model.selected.isEmpty {
                Text("Für diese Verbindung sind keine Dokumente mehr freigegeben. Um den Zugriff später fortzusetzen, wähle zuerst unter „Freigabe bearbeiten“ wieder Dokumente aus.")
            } else {
                Text(model.updatedAccessEnabled ? "Stelle jetzt eine Frage zu einem freigegebenen Dokument in deinem Chatbot." : "Der Dokumentzugriff ist pausiert. Du kannst ihn unter Verbindungen fortsetzen.")
                if !model.updatesChatGPT { Text("Lade bei Bedarf die Vauldy-Verbindung im Chatbot neu.").foregroundStyle(.secondary) }
            }
        }
    }

    private func rowStatus(_ row: MCPInventoryQualityReport.Row) -> String {
        if row.original == .changed { return "Original zuletzt verändert · neue Fassung benötigt eine eigene Freigabe" }
        if row.original == .unavailable { return "Original zuletzt nicht erreichbar · Zugriff wiederherstellen" }
        if !row.selectable { return "Noch nicht für den Chat nutzbar" }
        if model.profile.allowedDocumentIDs.contains(row.id) { return "Bereits freigegeben" }
        if model.selected.contains(row.id) { return "Für Freigabe ausgewählt · Originalprüfung bei Bestätigung" }
        if model.isKeptLocal(row.id) { return "Nur lokal behalten" }
        if row.processing == "source-ready" { return "Text eingelesen · Originalprüfung bei Bestätigung" }
        return "Text mit Prüfhinweisen · Originalprüfung bei Bestätigung"
    }
}
