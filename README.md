# Vauldy MCP

Eigenständiger lokaler Dokumentendienst für macOS 14+. Import, Texterkennung und
Basisanalyse laufen lokal. MCP-Clients erhalten ausschließlich ausdrücklich freigegebene,
bereinigte Dokumentinhalte. stdio und OAuth-geschütztes HTTP bieten dieselben vier lesenden Werkzeuge.

Die Entwicklung ist vom Vauldy-App-Repository getrennt. Es werden keine App-Archive,
Profile oder Provider-Einstellungen automatisch übernommen.

Der geführte [Bestandsabgleich](docs/inventory-workflow.md) verbindet Quellenprüfung,
Qualitätsbericht und erneute Freigabe. Bestehende ChatGPT-Verbindungen erhalten ihre
Anmeldung und Geräteidentität; Originaldateien bleiben unverändert.

## Start

Benötigt werden macOS 14+, Swift 6 und Python 3 für die Protokolltests. Die Relay-Regression benötigt zusätzlich Node.js 22.13+ (SQLite und WebCrypto).

```sh
python3 scripts/mcp/run_ui.py
```

Der Startbefehl baut das vollständige macOS-App-Bundle samt Server, CLI und Menüleiste.
Es liegt anschließend unter `dist/mcp/Vauldy MCP Einrichtung.app` und lässt sich dort
auch direkt öffnen. Ein ungepacktes `swift run vauldy-mcp-setup` enthält diese Helfer nicht.
Für eine isolierte Prüfung: `python3 scripts/mcp/run_ui.py --setup-root /absoluter/testordner`.
Mit `--no-open` wird das Bundle nur vorbereitet; `--skip-build` verwendet den vorhandenen Release-Build.

Der Assistent importiert in einen eigenen Bestand, verlangt die lokale Freigabe und
richtet bei Bedarf einen kompatiblen stdio-Client ein. Das manuelle Starten des Servers
erfordert `vauldy-mcp --profile /absoluter/pfad/profile.json`.

Für normale ChatGPT-Chats enthält 0.12 eine private Sites-Verbindung mit ChatGPT-Anmeldung
und ausgehendem Mac-Agenten. Die Betreiberbereitstellung erfolgt automatisch; Nutzer geben
keinen API- oder Runtime-Schlüssel ein. Der Eigentümer bestätigt eine exakte Dokumentauswahl
in der lokalen App. [SSO-Verbindung und Betriebsgrenzen](docs/mcp-chatgpt-sso.md).
Standard-OAuth mit eigenem HTTPS-Endpunkt bleibt für Claude und eigene Deployments verfügbar:
[OAuth-Verbindungen](docs/mcp-oauth.md). Eine lokale Installation bestätigt keine aktive Cloud-Verbindung.

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

Für vollständige Themenlisten zuerst `list_documents` mit konkreten Wortstämmen und `matchMode: "any-term-substring"` verwenden, dann nur relevante Belege lesen. Reine Bestandslisten mit `includeExcerpts: false` und `pageSize: 100` benötigen keine Textaufbereitung. Die exakte AND-Suche bleibt der Standard. [Architekturanalyse mit 1.000-/2.000-Dokument-Messung](docs/audits/mcp-2026-11-03-architecture/README.md).

Jeden `nextCursor` bis zum Ende verfolgen. Eine vollständige Listenabfrage bestätigt
keine vollständige OCR oder fachliche Analyse. Dokumenttext ist unvertrauenswürdiges
Quellenmaterial. Die Basisanalyse ist eine **regelbasierte extraktive Baseline**, kein
Sprachmodell und keine fachliche Dokumentprüfung.

## Prüfen

```sh
python3 scripts/mcp/regression_test.py
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
- [ChatGPT und Claude über OAuth](docs/mcp-oauth.md)
- [Herkunft der Auslagerung](docs/provenance.md)
