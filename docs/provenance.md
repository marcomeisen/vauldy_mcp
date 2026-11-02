# Herkunft und Abgrenzung

Der eigenständige MCP wurde aus `marcomeisen/vauldy`, Commit
`9b523749f52042bb159750401eb82170c6059ac9`, übernommen. Enthalten sind ausschließlich
das Swift-Paket, lokale MCP-Werkzeuge, synthetische Tests und MCP-Dokumentation.
Die frühere App bleibt unverändert. Ihre Archive und Modell-/Providerkonfigurationen
werden weder übernommen noch automatisch geöffnet.

`Sources/VauldyPrivacy` ist die mit diesem Stand übernommene lokale Kennungsbereinigung.
Sie wird in diesem Repo eigenständig versioniert. Die App-Kopie wird nicht mitgeschrieben.
Vor Änderungen an dieser Sicherheitsgrenze müssen die Privacy- und realen Wiretests bestehen.

Nicht übernommen: App-Ziele, App-Oberflächen, echte Dokumente, lokale Profile,
Clientkonfigurationen, Build-Caches und bereits gebaute Installationspakete.
