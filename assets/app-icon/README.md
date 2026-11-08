# Vauldy App-Icon

Gefaltetes weißes Dokument als V vor einem türkisfarbenen Archivordner auf einer
dunkelblauen macOS-Kachel. Mit dem integrierten ImageGen-Werkzeug am 08.11.2026 erstellt.
Der vollständige Erstellprompt liegt in `prompt.txt`.

- `Vauldy.png`: 1024 × 1024 Pixel, RGBA mit transparentem Außenbereich.
- `Vauldy.icns`: macOS-Icon mit zehn Standarddarstellungen von 16 bis 1024 Pixeln.

Das generierte Bild wurde ausschließlich mit `sips` auf die benötigten Größen
exportiert und mit `iconutil -c icns` in das macOS-Format umgewandelt.
`scripts/mcp/package.py` übernimmt das Icon vor der Signierung in Haupt- und
Status-App und setzt jeweils `CFBundleIconFile`.
