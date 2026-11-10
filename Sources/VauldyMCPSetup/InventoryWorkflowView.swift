import SwiftUI
import QuickLook
import VauldyCore
import VauldyMCPRuntime

struct InventoryWorkflowView: View {
    @ObservedObject var model: InventoryWorkflowModel
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: Inspection?
    @State private var confirmClose = false
    private struct Inspection: Identifiable { let id: UUID; var focus: LocalDocumentQuality.Focus? = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.step == 0 ? "Originalzugriff wiederherstellen" : "Dokumente freigeben").font(.title2.bold())
                    Text("Empfänger · \(model.profile.connectionName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.completed ? "Fertig" : "Schließen") {
                    if !model.completed && model.selectionChanged { confirmClose = true } else { dismiss() }
                }.disabled(model.busy)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.completed { completion }
                    else if model.step == 0 { sources }
                    else if model.step == 2 { consent }
                    else if let report = model.report { selection(report) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.progress)
                    Spacer()
                    if !model.committing { Button("Abbrechen") { model.task?.cancel() } }
                }
            }
            if !model.error.isEmpty {
                SetupNotice(text: model.error, warning: true)
                if !model.busy && !model.completed { Button("Dokumente erneut prüfen", action: model.reportOnly) }
            }
        }
        .padding(24).frame(minWidth: 700, idealWidth: 820, minHeight: 600)
        .task { await model.loadSources() }
        .sheet(item: $inspection) { item in
            SetupQualityReviewView(store: model.store, executable: model.localExecutable, documentID: item.id,
                initialPage: item.focus?.page, initialFocus: item.focus) { _ in model.reportOnly() }
        }
        .interactiveDismissDisabled(model.busy || (!model.completed && model.selectionChanged))
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { _, url in if url == nil { model.previewAccess?.close(); model.previewAccess = nil } }
        .confirmationDialog("Ungespeicherte Auswahl verwerfen?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Auswahl verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) { }
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
                ForEach(plan.issues) { issue in Text("\(issue.source) · \(issue.message)").foregroundStyle(.orange) }
                Button("Originale zuordnen und neue Dateien einlesen", action: model.importAndReport).buttonStyle(.borderedProminent)
            }
            Button("Zur Dokumentauswahl", action: model.reportOnly)
        }.disabled(model.busy)
    }

    private func selection(_ report: MCPInventoryQualityReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welche Dokumente darf \(model.profile.connectionName) lesen?").font(.headline)
            Text("\(model.selected.count) ausgewählt · \(model.addedCount) zusätzlich · \(model.removedCount) werden entfernt")
            if !model.isNewConnection {
                Toggle("Nur Dokumente mit offener Freigabeentscheidung", isOn: $model.onlyUnshared)
            }
            TextField("Dokumente suchen", text: $model.search).textFieldStyle(.roundedBorder)
            HStack {
                Button("Lesbare Treffer hinzufügen") {
                    model.selected.formUnion(model.visibleRows.filter(\.eligible).map(\.id))
                    model.acknowledged = false; model.acknowledgedReview = false
                }
                Spacer()
                Text("Geprüft \(report.createdAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if model.visibleRows.isEmpty { Text("Keine Dokumente in dieser Ansicht. Ändere die Suche oder zeige alle Dokumente.").foregroundStyle(.secondary) }
            ForEach(model.visibleRows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(row.title, isOn: Binding(get: { model.selected.contains(row.id) }, set: { model.setSelected($0, id: row.id) }))
                        .disabled(!row.eligible && !model.selected.contains(row.id) && !model.profile.allowedDocumentIDs.contains(row.id))
                    Text(rowStatus(row)).font(.callout).foregroundStyle(.secondary)
                    if model.usesLocalStore && (row.original == .unavailable || row.original == .changed) {
                        Button("Originalzugriff wiederherstellen") { model.step = 0 }
                    }
                    if model.usesLocalStore, let quality = model.qualityByID[row.id] {
                        DisclosureGroup("Prüfhinweise ansehen") {
                            SetupDocumentQualityView(quality: quality) { focus in inspection = .init(id: row.id, focus: focus) }
                        }
                    }
                    HStack {
                        if model.usesLocalStore && row.original == .available { Button("Original anzeigen") { model.preview(row.id) } }
                        if !model.isNewConnection && !model.profile.allowedDocumentIDs.contains(row.id) && !model.isKeptLocal(row.id) {
                            Button("Nur lokal behalten") { model.keepLocal(row.id) }
                        }
                    }.font(.caption)
                }.padding(.vertical, 8)
                Divider()
            }
            ForEach(Array(model.selected.subtracting(Set(report.rows.map(\.id)))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                Toggle("Gespeichertes Dokument \(id.uuidString.prefix(8)) · derzeit nicht im Bestand", isOn: Binding(get: { model.selected.contains(id) }, set: { model.setSelected($0, id: id) }))
            }
            ForEach(model.importIssues) { issue in Text("\(issue.source) · \(issue.message)").foregroundStyle(.orange) }
            HStack {
                Button("Dokumente erneut prüfen", action: model.reportOnly)
                Spacer()
                Button("Auswahl überprüfen") { model.step = 2; model.acknowledged = false; model.acknowledgedReview = false }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isNewConnection ? model.selected.isEmpty : (!model.selectionChanged && !model.updatesChatGPT))
            }
        }.disabled(model.busy)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Freigabe für \(model.profile.connectionName)").font(.headline)
            Text("Danach \(model.selected.count) Dokumente freigegeben · \(model.addedCount) zusätzlich · \(model.removedCount) entfernt")
            ForEach(model.report?.rows.filter { model.selected.contains($0.id) != model.profile.allowedDocumentIDs.contains($0.id) } ?? []) { row in
                Label(row.title, systemImage: model.selected.contains(row.id) ? "plus.circle" : "minus.circle")
            }
            ForEach(Array(model.profile.allowedDocumentIDs.subtracting(model.selected).subtracting(Set(model.report?.rows.map(\.id) ?? []))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                Label("Gespeichertes Dokument \(id.uuidString.prefix(8)) entfernen", systemImage: "minus.circle")
            }
            let localRows = model.report?.rows.filter { !model.selected.contains($0.id) } ?? []
            if !localRows.isEmpty {
                DisclosureGroup("\(localRows.count) weitere Dokumente für diese Verbindung nur lokal behalten") {
                    ForEach(localRows) { row in Text(row.title) }
                }
            }
            Text("Angeforderte Inhalte werden auf diesem Mac zum Schutz persönlicher Daten aufbereitet und an diesen Chatbot und gegebenenfalls seinen Cloud-Anbieter übertragen. Die Originaldateien bleiben auf deinem Mac.")
            if !model.profile.enabled && !model.isNewConnection { Text("Der Dokumentzugriff ist pausiert. Die neue Auswahl wird für später gespeichert.").foregroundStyle(.orange) }
            if model.selected.isEmpty { Text("Du entfernst alle Dokumente aus der Freigabe. Dadurch wird der Dokumentzugriff pausiert.").foregroundStyle(.orange) }
            if model.reviewCount > 0 {
                Toggle("Die \(model.reviewCount) ausgewählten Dokumente mit Prüfhinweisen dürfen mit ihren Einschränkungen verwendet werden.", isOn: $model.acknowledgedReview)
            }
            Toggle("Ich erlaube diesem Empfänger den Zugriff auf die angezeigte Dokumentauswahl.", isOn: $model.acknowledged)
            HStack {
                Button("Auswahl bearbeiten") { model.step = 1 }
                Spacer()
                Button(model.selected.isEmpty ? "Alle Dokumentfreigaben entfernen" : "Auswahl für \(model.profile.connectionName) freigeben", action: model.prepareApproval)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.acknowledged || (model.reviewCount > 0 && !model.acknowledgedReview))
            }
        }.disabled(model.busy)
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Freigabe gespeichert", systemImage: "checkmark.circle.fill").font(.title3)
            Text("\(model.selected.count) Dokumente für \(model.profile.connectionName) ausgewählt.")
            if model.isNewConnection {
                Text("Schließe dieses Fenster, um die Einrichtung der Verbindung fortzusetzen.")
            } else {
                Text(model.updatedAccessEnabled ? "Stelle jetzt eine Frage zu einem freigegebenen Dokument in deinem Chatbot." : "Der Dokumentzugriff ist pausiert. Du kannst ihn unter Verbindungen fortsetzen.")
                if !model.updatesChatGPT { Text("Lade bei Bedarf die Vauldy-Verbindung im Chatbot neu.").foregroundStyle(.secondary) }
            }
        }
    }

    private func rowStatus(_ row: MCPInventoryQualityReport.Row) -> String {
        if row.original == .changed { return "Original verändert · neue Fassung benötigt eine eigene Freigabe" }
        if row.original == .unavailable { return "Original nicht erreichbar · derzeit nicht im Chat nutzbar" }
        if !row.eligible { return "Noch nicht für den Chat nutzbar" }
        if model.profile.allowedDocumentIDs.contains(row.id) { return "Bereits freigegeben" }
        if model.isKeptLocal(row.id) { return "Nur lokal behalten" }
        return row.ready ? "Text eingelesen · Freigabe ausstehend" : "Lesbar mit Prüfhinweisen · Freigabe ausstehend"
    }
}
