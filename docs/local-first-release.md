# Lokaler Release und Kundenabnahme

## Release erzeugen

Für jedes Artefakt eine neue Ausgabeablage verwenden. Aus dem eigenständigen Repository bauen, die Toolchain festhalten und `Package.resolved` einchecken. `MCPBuild.swift` ist die Produktversionsquelle. Der Paketbuild prüft die Versionen und Architektur aller Programme, bevor er das Paket schreibt. Beide App-Bundles erhalten dieselbe Produktversion. Das signierte Bundle enthält `Contents/Resources/release.json` mit Layout, Toolchain, Architektur, Mindest-OS und Lockfile-Hash. Ein verifizierter sauberer Neubau kann den Quellcommit ausweisen. Ein Build mit `--skip-build` hat keine Commit-Zuordnung.

```sh
python3 scripts/mcp/package.py --output ./dist/mcp/internal
```

Das Ad-hoc-Artefakt dient isolierten internen Tests. Für einen Kundenkandidaten benötigt die Release-verantwortliche Person einen sauberen Git-Checkout, die pinned Abhängigkeiten, ein gültiges **Developer ID Application**-Zertifikat mit privatem Schlüssel und ein bereits eingerichtetes `notarytool`-Profil für das richtige Apple-Team. Das ZIP enthält ein App-Bundle. Ein Developer ID Installer-Zertifikat wäre für ein späteres signiertes PKG erforderlich.

```sh
python3 scripts/mcp/package.py --output ./dist/mcp/customer-candidate \
  --identity 'Developer ID Application: TEAM-NAME (TEAM-ID)' \
  --notary-profile 'VORHANDENES-PROFIL'
```

Der Build verwendet für Developer ID eine frische Build-Ablage. Der signierte Pfad nutzt Hardened Runtime und Zeitstempel. Bei angegebenem Notary-Profil reicht das Skript das ZIP bei Apple ein, stapelt und validiert das Ticket, prüft Gatekeeper und packt erneut. Vergleiche `SHA256SUMS` über einen vertrauenswürdigen Bezugskanal. Layout und Eingaben sind nachvollziehbar. Zeitstempel und Notarisierung verhindern einen Anspruch auf byteidentische ZIPs.

Abnahme auf einem frischen Mac jeder unterstützten Architektur mit geplanter Mindestversion. Lade das ZIP über den vorgesehenen Vertriebskanal, prüfe Hash, Team-ID, Signatur, Ticket und Gatekeeper. Installiere mit Testbenutzer und synthetischer Freigabe. Deaktiviere danach Netzwerk und Relay. Belege lokalen Import/OCR, vollständige stdio-Inventarliste, Quellenlesung und Widerruf. Teste den Zielclient separat. [Apple-Vorgaben für macOS-Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Update und Rückweg

Der vorhandene explizite Softwareupdatepfad hält eine Prozesssperre und ersetzt einzelne Dateien atomar. Er prüft mitgelieferte CLI, Status-App und Setup-Bundle-Kennung vor dem ersten Programmaustausch. Die bestehende Konfiguration und der Vault gehören nicht zum Update. Das Bundlemanifest ist Build-Evidenz. Es ist noch kein signierter Updatefeed und kein Laufzeit-Kompatibilitätsnachweis.

Vor einem freigegebenen Update das vorherige verifizierte Release aufbewahren. Je Release die Matrix für Profilformat, Storeformat, Worker-IPC und MCP-Discovery festhalten. Der aktuelle Stand akzeptiert Profilformat 1, der eigenständige Store verwendet Marker 2, der lokale Worker meldet IPC 2. Produktversion und MCP-Protokollversion sind davon unabhängig. Die App und der eigenständige Store haben unterschiedliche Eigentümer und dürfen sich keinen Writer teilen.

Software-Rückkehr vorerst nur nach einem erfolgreich geprobten Rückweg mit derselben Formatmatrix. Lokale Client-/Workerprozesse für die isolierte Probe kontrolliert beenden. Vorheriges vollständiges Release über dessen eigene vertrauenswürdige CLI in den synthetischen Installationsroot einspielen, die vier Werkzeuge und den Start neu prüfen und Archiv, Profil, Originale und Clientdateien byteweise vergleichen. Bei inkompatiblen oder unbekannten Formaten bleibt der Stand gesperrt, bis ein freigegebener kompatibler Reparaturpfad vorliegt. Keine Archiv-/Profilkopie als Bestandteil eines Software-Rollbacks zurückspielen.

## Priorisierte Abnahmetickets

| Reihenfolge | Ticket | Abnahme |
| --- | --- | --- |
| 1 | P0 · Vertrauenswürdiger Release und CI | Paketzusammenbau, Versions- und Architekturprüfung, Regression und Schema-Parität auf sauberem macOS-Runner. Team-ID, Gatekeeper und Ticket auf frischem Kunden-Mac belegen. Signierung und Notarisierung erst mit autorisierter Release-Umgebung ausführen. |
| 2 | P0 · Vollständiges Softwareupdate und Rückweg | Signierten Herausgeber, Hashes und Kompatibilität vor Aktivierung prüfen. Alle Softwarebestandteile gemeinsam aktivieren, Probe vor und nach Umschalten, Rückkehr bei Fehler. Falsche Signatur, falsche Version, Schreibfehler, Stromausfall und parallele Updates mit Fixtures prüfen. Daten, Profile, Audit, OAuth, Keychain und Host-Konfiguration bytegleich halten. |
| 3 | P0 · Agensi-Pilot | In einem Zielclient das Anweisungspaket und bestehenden lokalen Vauldy MCP getrennt laden. Synthetische Recherche über mehrere Inventar- und Leseseiten, Quellen und Widerruf prüfen. Bei Agensi den vorhandenen lokalen MCP unter „Needs access“ ausweisen. [Agensi-Format und Angebotsgrenzen](https://www.agensi.io/docs/what-you-can-sell) |
| 4 | P1 · Gemeinsamer Core | Je gemeinsamem Pfad Eigentümer und API bestimmen. Ein erstes identisches Modell oder einen kleinen Quellenvertrag extrahieren. App- und MCP-Adapter gegen Altfixtures prüfen, anschließend nur belegte Duplikate entfernen. Veröffentlichung gemeinsamer Quellen separat entscheiden. |
| 5 | P1 · 20.000 Dokumente | Größenreihe auf Referenz-Mac mit Freigaben, realistischen Dokumentlängen, Speicherspitzen, Wiederholungen, Suchbelegen und Worker-/Importlast ausführen. Zielwerte vor Abnahme festlegen. Vergleichbarer read-only Indexversuch nur bei belegtem Engpass. Alte JSON-Daten weiter lesen, Backup/Restore und Abbruch testen. |
| 6 | P1 · Resilienz | Synthetische Crash-/Cancel-Proben mit tatsächlicher nativer OCR, kontrollierten CPU-/Speichergrenzen und Wiederaufnahme. Diagnosen auf technische Zähler begrenzen. |
| 7 | Optional · Remote und Lizenz | Separaten Architekturvorschlag mit Zweck, widerrufbarer Zustimmung, Gerätebindung, Aufbewahrung und Offline-Test liefern. Lokaler stdio-Betrieb bleibt unabhängig. |
