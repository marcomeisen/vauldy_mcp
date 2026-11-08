import Foundation

/// JSON compatibility limits. These are not a capacity promise for 20,000 long documents.
public enum VaultStorageLimits {
    public static let snapshotBytes = 128 * 1_024 * 1_024
    public static let importedDocuments = 20_000
}

/// Not stored in the legacy Codable job error enum: older readers remain compatible.
public enum LocalStoreCapacityError: String, LocalizedError, Equatable, Codable, Sendable {
    case documentCount, snapshotBytes
    public var errorDescription: String? {
        switch self {
        case .documentCount:
            "Der lokale JSON-Bestand hat die Importgrenze von 20.000 Dokumenten erreicht. Dieses Dokument wurde nicht hinzugefügt. Bestehende Dokumente und Freigaben bleiben erhalten."
        case .snapshotBytes:
            "Der lokale JSON-Bestand erreicht die Grenze von 128 MiB. Diese Änderung wurde nicht gespeichert. Bestand und Sicherung bleiben erhalten. Weitere Importe bitte aussetzen; ein erneuter OCR-Versuch schafft keinen Speicherplatz."
        }
    }
}
