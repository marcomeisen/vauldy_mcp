#!/bin/bash
set -euo pipefail

# Only environment references are persisted in the vendor profile. Never echo a key.
vauldy_root="${1:-$HOME/Library/Application Support/VauldyMCP}"
vauldy_client="$vauldy_root/bin/tunnel-client"
vauldy_config="$vauldy_root/tunnel/vauldy-chatgpt.yaml"

if [[ ! -x "$vauldy_client" || ! -f "$vauldy_config" ]]; then
    printf 'Die lokale Tunnel-Einrichtung fehlt. Bitte zuerst Client und Tunnel-Profil einrichten.\n'
    exit 1
fi

printf 'Vauldy → privater ChatGPT-Tunnel\n'
printf 'Es gelten die ausdrücklich gespeicherten Dokumentfreigaben deiner Verbindung.\n'
printf 'Ein Runtime-Schlüssel benötigt Tunnels Read + Use. Keinen Admin-Schlüssel verwenden.\n'
printf 'Der Schlüssel wird weder in dieser Datei noch im Profil gespeichert.\n\n'

if [[ -z "${CONTROL_PLANE_API_KEY:-}" ]]; then
    read -r -s -p 'OpenAI-Runtime-Schlüssel (Eingabe unsichtbar): ' CONTROL_PLANE_API_KEY
    printf '\n'
fi
if [[ -z "$CONTROL_PLANE_API_KEY" ]]; then
    printf 'Kein Schlüssel eingegeben. Der Tunnel wurde nicht gestartet.\n'
    exit 1
fi
export CONTROL_PLANE_API_KEY
trap 'unset CONTROL_PLANE_API_KEY' EXIT

"$vauldy_client" doctor --config "$vauldy_config" --mcp.stdio-send-initialized-notification --explain
printf '\nPrüfung abgeschlossen. Der Tunnel verbindet den freigegebenen Bestand mit ChatGPT.\n'
read -r -p 'Zum Starten START eingeben, andernfalls Enter: ' vauldy_decision
if [[ "$vauldy_decision" != START ]]; then
    printf 'Abgebrochen. Der Tunnel wurde nicht gestartet.\n'
    exit 0
fi
printf 'Der Tunnel läuft, solange dieses Terminal geöffnet bleibt. Beenden mit Control-C.\n'
exec "$vauldy_client" run --config "$vauldy_config" \
    --mcp.stdio-send-initialized-notification \
    --health.url-file "$vauldy_root/tunnel/health.url"
