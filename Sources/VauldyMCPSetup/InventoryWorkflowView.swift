import SwiftUI
import QuickLook
import VauldyCore
import VauldyMCPRuntime

struct InventoryWorkflowView: View {
    @ObservedObject var model: InventoryWorkflowModel
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: Inspection?
    private struct Inspection: Identifiable { let id: UUID; var focus: LocalDocumentQuality.Focus? = nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Bestand und Chatfreigabe aktualisieren").font(.title2.bold())
                Spacer()
                Button(model.completed ? "Fertig" : "Schließen") { dismiss() }.disabled(model.busy)
            }
            Text("\(model.profile.connectionName) · Originaldateien bleiben unverändert.").foregroundStyle(.secondary)
            HStack {
                stage("1 · Bestand abgleichen", index: 0)
                Image(systemName: "chevron.right")
                stage("2 · Qualitätsbericht", index: 1)
                Image(systemName: "chevron.right")
                stage("3 · Neu freigeben", index: 2)
            }.font(.callout)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.completed { completion }
                    else if model.step == 0 { sources }
                    else if model.step == 1 { quality }
                    else { consent }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text(model.progress); Spacer(); if !model.committing { Button("Abbrechen") { model.task?.cancel() } } }
            }
            if !model.error.isEmpty { SetupNotice(text: model.error, warning: true) }
        }.padding(24).frame(minWidth: 780, idealWidth: 880, minHeight: 620)
        .task { await model.loadSources() }
        .sheet(item: $inspection) { item in
            SetupQualityReviewView(store: model.store, executable: model.localExecutable, documentID: item.id,
                initialPage: item.focus?.page, initialFocus: item.focus) { _ in model.reportOnly() }
        }
        .interactiveDismissDisabled(model.busy)
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { _, url in if url == nil { model.previewAccess?.close(); model.previewAccess = nil } }
        .confirmationDialog("Aktualisierte Dokumentfreigabe bestätigen?", isPresented: Binding(get: { model.approval != nil }, set: { if !$0 { model.approval = nil } }), titleVisibility: .visible) {
            if let approval = model.approval { Button("Bestätigte Auswahl übernehmen") { model.confirm(approval) } }
            Button("Abbrechen", role: .cancel) { model.approval = nil }
        } message: {
            if let approval = model.approval {
                Text("\(SetupText.documents(approval.ids.count)) für „\(approval.profile.connectionName)“. Die bisherige Auswahl wird ersetzt. \(model.updatesChatGPT ? "Die ChatGPT-Anmeldung und das Ablaufdatum bleiben erhalten." : "Der bisherige Freigabestatus bleibt erhalten.") Originale werden nicht verändert. Eine leere Auswahl pausiert den Zugriff.")
            }
        }
    }
    private func stage(_ title: String, index: Int) -> some View {
        Text(title).foregroundStyle(model.step == index ? Color.accentColor : .secondary).fontWeight(model.step == index ? .semibold : .regular)
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wähle die Quellen für den einmaligen Abgleich. Bestehende Einträge bleiben erhalten, auch wenn ein Original fehlt. Eine bestehende Ordnerüberwachung läuft unabhängig.")
            Toggle("Neue Quellordner einschließlich Unterordnern", isOn: $model.recursive)
            ForEach(model.sources) { folder in
                Toggle(isOn: Binding(get: { model.sourceIDs.contains(folder.id) }, set: { value in
                    if value { model.sourceIDs.insert(folder.id) } else { model.sourceIDs.remove(folder.id) }; model.plan = nil
                })) { Text(folder.path).textSelection(.enabled); Text(folder.recursive ? "Mit Unterordnern" : "Ohne Unterordner").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Quellordner auswählen …", action: model.chooseSources)
                Button("Bestand abgleichen", action: model.inspect).disabled(model.sourceIDs.isEmpty)
                Button("Nur vorhandenen Bestand prüfen", action: model.reportOnly)
            }
            Text("Erfasst werden unterstützte PDFs und Bilder. Versteckte Dateien, Pakete und symbolische Links bleiben unberücksichtigt; Zugriffs- und Größenprobleme werden angezeigt.").font(.caption).foregroundStyle(.secondary)
            if let plan = model.plan {
                Text("\(plan.files.filter { $0.change == .added }.count) neue · \(plan.files.filter { $0.change == .changed }.count) geänderte · \(plan.files.filter { $0.change == .unchanged }.count) vorhandene · \(plan.files.filter { $0.change == .pending }.count) ausstehende Dateien · \(plan.files.filter { $0.change == .renewAccess }.count) Originalzugriffe erneuern · \(plan.duplicates) inhaltsgleiche weitere Dateien").font(.headline)
                issues(plan.issues)
                Text("Der Abgleich hat bisher keine Dokumente importiert oder freigegeben.").font(.callout)
                Button("\(plan.importCount == 1 ? "1 Datei" : "\(plan.importCount) Dateien") einlesen und Qualität prüfen", action: model.importAndReport).buttonStyle(.borderedProminent)
            }
        }.disabled(model.busy)
    }
    private var quality: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text("\(SetupText.documents(report.rows.count)) im gesamten lokalen Bestand").font(.headline)
                Text("\(report.readyIDs.count) ohne offene automatische Verarbeitungs-/Analysehinweise · \(report.reviewIDs.count) lesbar mit Prüfhinweisen · \(report.rows.count - report.eligibleIDs.count) derzeit nicht neu freigebbar")
                Text("Geprüft: \(report.createdAt.formatted()). Originalzugriff, Seitenabdeckung und regelbasierte Basisanalyse werden getrennt bewertet. Kein Nachweis fachlicher Richtigkeit.").font(.callout).foregroundStyle(.secondary)
                issues(model.importIssues)
                HStack {
                    Button("Ohne offene Hinweise auswählen", action: model.selectReady)
                    Button("Alle lesbaren auswählen", action: model.selectReadable)
                    Spacer(); Text("\(model.selected.count) ausgewählt")
                }
                TextField("Bericht durchsuchen", text: $model.search).textFieldStyle(.roundedBorder)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.visibleRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(row.title, isOn: Binding(get: { model.selected.contains(row.id) }, set: { model.setSelected($0, id: row.id) })).disabled(!row.eligible)
                            Text("Original: \(originalLabel(row.original))").font(.caption).foregroundStyle(.secondary)
                            if let quality = model.qualityByID[row.id] {
                                SetupDocumentQualityView(quality: quality) { focus in inspection = .init(id: row.id, focus: focus) }
                            } else {
                                Text("Keine gespeicherte Detailprüfung verfügbar.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if row.original == .available { Button("Original anzeigen") { model.preview(row.id) }.font(.caption) }
                                Button("Prüfstellen ansehen") { inspection = .init(id: row.id) }.font(.caption)
                            }
                        }
                    }
                }
                HStack {
                    Button("Zurück zu den Quellen") { model.step = 0; model.plan = nil }
                    Button("Bericht erneut prüfen", action: model.reportOnly)
                    Spacer()
                    Button("Auswahl überprüfen") { model.step = 2; model.acknowledged = false; model.acknowledgedReview = false }.buttonStyle(.borderedProminent)
                }
            }
        }.disabled(model.busy)
    }
    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(SetupText.documents(model.selected.count)) für „\(model.profile.connectionName)“").font(.headline)
            Text("\(model.addedCount) zusätzlich · \(model.removedCount) aus der bisherigen Freigabe entfernt · \(model.reviewCount) mit Prüfhinweisen")
            Text("Angeforderte freigegebene Inhalte werden auf diesem Mac bereinigt und an den Chatbot übertragen. Originaldateien bleiben lokal. Neue Importe bleiben außerhalb dieser bestätigten Auswahl.")
            if model.updatesChatGPT { Text("Deine ChatGPT-Verbindung bleibt bestehen. Die Aktualisierung verlängert ihre Laufzeit nicht. Während des Umschaltens wird der Mac-Dienst kurz angehalten.") }
            if !model.profile.enabled { Text("Diese Verbindung ist pausiert und bleibt auch nach dem Speichern pausiert.").foregroundStyle(.orange) }
            if model.selected.isEmpty { Text("Die leere Auswahl pausiert den Dokumentzugriff.").foregroundStyle(.orange) }
            if model.reviewCount > 0 { Toggle("Die ausgewählten Dokumente mit Prüfhinweisen dürfen unter Angabe ihrer Einschränkungen verwendet werden.", isOn: $model.acknowledgedReview) }
            Toggle("Ich bestätige Empfänger, Dokumentauswahl und mögliche Weitergabe an dessen Cloud-Anbieter.", isOn: $model.acknowledged)
            HStack {
                Button("Auswahl bearbeiten") { model.step = 1; model.acknowledged = false }
                Spacer()
                Button("Freigabe aktualisieren", action: model.prepareApproval)
                    .buttonStyle(.borderedProminent).disabled(!model.acknowledged || (model.reviewCount > 0 && !model.acknowledgedReview))
            }
        }.disabled(model.busy)
    }
    private var completion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Freigabe aktualisiert", systemImage: "checkmark.circle.fill").font(.title3)
            Text(model.updatedAccessEnabled ? "Die bestätigte Auswahl wurde gespeichert. Die Verbindung ist freigegeben." : "Die Auswahl wurde gespeichert. Der Dokumentzugriff ist pausiert.")
            Text(model.updatesChatGPT ? "Die ChatGPT-Anmeldung bleibt erhalten. Prüfe im Chat den Vauldy-Status und beginne eine neue Dokumentliste; bisherige Fortsetzungen können durch die aktualisierte Auswahl ungültig sein." : "Lade die Verbindung im Chatbot neu und prüfe den Vauldy-Status.")
            Text("Originale wurden nicht verändert. Der Qualitätsbericht bestätigt Verarbeitung und Quellenzugriff; Angaben im Chat benötigen weiterhin Belege.").foregroundStyle(.secondary)
        }
    }
    private func issues(_ values: [LocalInventoryPlan.Issue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !values.isEmpty { Text("\(values.count) offene Hinweise – der Quellenabgleich ist nicht uneingeschränkt vollständig.").foregroundStyle(.orange) }
            ForEach(values) { value in Text("\(value.source): \(value.message)").font(.caption) }
        }
    }
    private func originalLabel(_ value: LocalOriginalState?) -> String {
        switch value { case .available: "erreichbar und inhaltsgleich"; case .changed: "verändert"; case .unavailable: "nicht erreichbar oder Zugriff fehlt"; case nil: "nicht überprüfbar" }
    }
    private func analysisLabel(_ value: String) -> String {
        switch value { case "completed": "vorhanden"; case "needsReview": "prüfen"; case "stale": "veraltet"; case "failed": "fehlgeschlagen"; case "unavailable": "nicht verfügbar"; default: "nicht vorhanden" }
    }
}
