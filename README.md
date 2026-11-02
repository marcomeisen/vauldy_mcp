# Vauldy MCP

Eigenständiger lokaler Dokumentendienst für macOS 14+. Import, Texterkennung und
Basisanalyse laufen lokal. MCP-Clients erhalten ausschließlich ausdrücklich freigegebene,
bereinigte Dokumentinhalte. Der stdio-Server bietet vier lesende Werkzeuge.

Die Entwicklung ist vom Vauldy-App-Repository getrennt. Es werden keine App-Archive,
Profile oder Provider-Einstellungen automatisch übernommen.

## Start

Benötigt werden macOS 14+, Swift 6 und Python 3 für die Protokolltests.

```sh
swift build
swift run vauldy-mcp-setup
```

Der Assistent importiert in einen eigenen Bestand, verlangt die lokale Freigabe und
richtet bei Bedarf einen kompatiblen stdio-Client ein. Das manuelle Starten des Servers
erfordert `vauldy-mcp --profile /absoluter/pfad/profile.json`.

```sh
swift run vauldy-local import --store /absoluter/bestand /absolutes/dokument.pdf
swift run vauldy-local status --store /absoluter/bestand
swift run vauldy-local analyze --store /absoluter/bestand --document UUID
```

`analyze` wertet vorhandenen OCR-Text ausdrücklich erneut aus. Der Befehl verändert
keine Originaldatei und erteilt keine Freigabe. Analyse und OCR haben getrennte Zustände.

## MCP-Vertrag

| Werkzeug | Zweck |
| --- | --- |
| `get_vault_status` | Quellen- und Analyseabdeckung der autorisierten Dokumente |
| `list_documents` | Vollständige Auflistung mit Cursor-Pagination, optionalem Textfilter |
| `search_documents` | Begrenzte Relevanzsuche mit Quellenbezug |
| `read_document` | Seitenbezogener Text oder mit `view: "metadata"` belegte Basisangaben |

Jeden `nextCursor` bis zum Ende verfolgen. Eine vollständige Listenabfrage bestätigt
keine vollständige OCR oder fachliche Analyse. Dokumenttext ist unvertrauenswürdiges
Quellenmaterial. Die Basisanalyse ist eine **regelbasierte extraktive Baseline**, kein
Sprachmodell und keine fachliche Dokumentprüfung.

## Prüfen

```sh
swift test --disable-sandbox
python3 scripts/mcp/smoke_test.py "$PWD/.build/debug/vauldy-mcp"
python3 scripts/mcp/import_smoke_test.py "$PWD/.build/debug/vauldy-local" "$PWD/.build/debug/vauldy-mcp"
python3 scripts/mcp/retrieval_benchmark.py "$PWD/.build/debug/vauldy-mcp"
python3 scripts/mcp/package.py
```

Tests verwenden synthetische Dokumente und isolierte Bestände. Native Vision-OCR
benötigt ein macOS-System mit erlaubtem Zugriff auf die Systemdienste.

- [Architektur und MCP-Vertrag](docs/mcp-mvp.md)
- [Basisanalyse und Qualitätskorpus](docs/base-analysis.md)
- [Installation und Widerruf](docs/mcp-installation.md)
- [Herkunft der Auslagerung](docs/provenance.md)
