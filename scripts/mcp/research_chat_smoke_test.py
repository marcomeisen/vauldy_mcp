#!/usr/bin/env python3
"""Accept the chat bridge against real stdio and optionally the installed local Codex host."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time

from research_agent_smoke_test import atomic_json, check_network_denied, check_result, fixture
from stdio_client import Client

TOOL = "research_insurance_contracts"
HOST_NAME = "vauldy_research_test"
SCRIPT = Path(__file__).with_name("research_agent.py").resolve()


def bridge_flags(server, planner=None, timeout=None):
    options = ["--python", sys.executable, "--agent", str(SCRIPT), "--server", str(server)]
    if planner:
        options += ["--planner", str(planner)]
    if timeout:
        options += ["--timeout", str(timeout)]
    return options


def successful(result):
    assert result.get("isError") is False
    report = result["structuredContent"]
    assert check_result(report) == 3
    text = result["content"][0]["text"]
    for fragment in ("| Versicherer | Vertragsnummer | Kündigungsfrist |",
                     "Pseudonymisiert", "Nicht belegt", "Widersprüchlich", "unvollständig",
                     "Textkandidaten ohne Vertragsbeleg (1)", "Kandidaten mit fehlender oder fehlgeschlagener Verarbeitung (1)"):
        assert fragment in text
    assert text.count("| Nordstern") == 1 and "PRIVAT-POL-11" not in text
    visible = text.replace("\\", "")
    for row in report["rows"]:
        assert row["contractEvidence"]["source"] in visible
        for field in row["fields"].values():
            if "source" in field:
                assert field["source"] in visible
            for evidence in field.get("evidence", []):
                assert evidence["source"] in visible
    return report["planner"]


def failed(result, reason):
    assert result.get("isError") is True
    assert result["structuredContent"] == {
        "status": "incomplete", "reason": reason, "inventoryComplete": False, "rows": [],
    }
    text = result["content"][0]["text"]
    assert "keine Dokumentzeilen" in text and "| Versicherer" not in text


def wait_until(condition, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.01)
    raise AssertionError("Expected subprocess state not observed")


def delayed_planner(root):
    marker, gate, planner = root / "planner-ready", root / "planner-go", root / "slow-planner"
    planner.write_text(f"""#!{sys.executable}
import os
from pathlib import Path
import time
marker = Path({str(marker)!r})
marker.write_text(str(os.getpid()))
while not Path({str(gate)!r}).exists():
    time.sleep(0.02)
print("police")
""")
    planner.chmod(0o700)
    return planner, marker, gate


def child_alive(marker):
    try:
        os.kill(int(marker.read_text()), 0)
        return True
    except ProcessLookupError:
        return False
    except ValueError:
        return True


def assert_no_reply(client, request_id, seconds=0.5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if b"\n" not in client.pending:
            if not client.selector.select(max(0, deadline - time.monotonic())):
                return
            chunk = os.read(client.process.stdout.fileno(), 65_536)
            assert chunk, "Chat bridge exited after cancellation"
            client.pending += chunk
            continue
        line, client.pending = client.pending.split(b"\n", 1)
        assert json.loads(line).get("id") != request_id, "Cancelled research returned a response"


def begin_call(client):
    client.counter += 1
    client.send({"jsonrpc": "2.0", "id": client.counter, "method": "tools/call",
                 "params": {"name": TOOL, "arguments": {}}})
    return client.counter


def call_result(client, request_id):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if b"\n" not in client.pending:
            if not client.selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(client.process.stdout.fileno(), 65_536)
            assert chunk
            client.pending += chunk
            continue
        line, client.pending = client.pending.split(b"\n", 1)
        response = json.loads(line)
        if response.get("id") == request_id:
            return response["result"]
    raise AssertionError("No chat response")


def wire_check(root, bridge, server, profile, grant, planner):
    client = Client(bridge, profile, server_options=bridge_flags(server, planner))
    try:
        tools = client.request("tools/list", {})["tools"]
        assert [tool["name"] for tool in tools] == [TOOL]
        assert tools[0]["inputSchema"]["additionalProperties"] is False
        failed(client.call(TOOL, profile="/not-allowed.json"), "invalid-arguments")
        observed = successful(client.call(TOOL))
        assert observed == ("apple-on-device" if planner else "fixed-request")
    finally:
        client.close()

    slow, marker, gate = delayed_planner(root)
    client = Client(bridge, profile, server_options=bridge_flags(server, slow))
    try:
        request_id = begin_call(client)
        wait_until(lambda: marker.exists() and marker.stat().st_size > 0)
        failed(client.call(TOOL), "busy")
        client.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": request_id}})
        wait_until(lambda: not child_alive(marker))
        assert_no_reply(client, request_id)

        marker.unlink()
        request_id = begin_call(client)
        wait_until(lambda: marker.exists() and marker.stat().st_size > 0)
        atomic_json(profile, grant | {"enabled": False})
        gate.touch()
        failed(call_result(client, request_id), "mcp-denied-or-stale")
        atomic_json(profile, grant)
        successful(client.call(TOOL))
    finally:
        client.close()

    gate.unlink()
    client = Client(bridge, profile, server_options=bridge_flags(server, slow, timeout=1))
    try:
        failed(client.call(TOOL), "timeout")
    finally:
        client.close()
    return observed


class LocalCodex(Client):
    def __init__(self, codex, root, bridge, server, profile, planner):
        codex_directory = root / "codex-test-config"
        codex_directory.mkdir(mode=0o700)
        argv = ["--profile", str(profile), *bridge_flags(server, planner)]
        config = f"""[analytics]
enabled = false

[mcp_servers.{HOST_NAME}]
command = {json.dumps(str(bridge), ensure_ascii=False)}
args = {json.dumps(argv, ensure_ascii=False)}
required = true
tool_timeout_sec = 65
"""
        (codex_directory / "config.toml").write_text(config)
        env = {"PATH": os.environ["PATH"], "CODEX_HOME": str(codex_directory), "TMPDIR": str(root)}
        self.process = subprocess.Popen([str(codex), "app-server", "--stdio"], cwd=root, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.counter = 0
        self.pending = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.request("initialize", {
                "clientInfo": {"name": "vauldy-isolated-acceptance", "version": "1"},
                "capabilities": {"experimentalApi": True},
            }, timeout=20)
            self.send({"jsonrpc": "2.0", "method": "initialized"})
        except BaseException:
            self.close(abort=True)
            raise


def freetext_turn(router, prompt, invoke):
    selected = subprocess.run([str(router)], input=prompt, text=True, capture_output=True,
                              check=True, timeout=30)
    calls = json.loads(selected.stdout)
    if calls == []:
        return None, "Diese Frage wurde keinem Vauldy-Recherchewerkzeug zugeordnet."
    if calls != [TOOL]:
        raise AssertionError("Unexpected local model tool selection")
    result = invoke()
    return result, result["content"][0]["text"]


def codex_check(root, codex, bridge, server, profile, grant, planner, router):
    host = LocalCodex(codex, root, bridge, server, profile, planner)
    try:
        result = host.request("thread/start", {"cwd": str(root), "ephemeral": True,
                                              "sandbox": "read-only", "approvalPolicy": "never"}, timeout=25)
        thread_id = result["thread"]["id"]
        listed = host.request("mcpServerStatus/list", {"threadId": thread_id, "serverName": HOST_NAME}, timeout=25)
        servers = listed["data"]
        assert len(servers) == 1 and TOOL in servers[0]["tools"]
        params = {"threadId": thread_id, "server": HOST_NAME, "tool": TOOL, "arguments": {}}
        calls = 0

        def invoke():
            nonlocal calls
            calls += 1
            return host.request("mcpServer/tool/call", params, timeout=40)

        expected_mode = "apple-on-device" if planner else "fixed-request"
        if router is None:
            assert successful(invoke()) == expected_mode
            atomic_json(profile, grant | {"enabled": False})
            failed(invoke(), "mcp-denied-or-stale")
            atomic_json(profile, grant)
            return None

        for question in (
            "Welche Versicherungsverträge habe ich? Bitte als Tabelle mit Versicherer, Vertragsnummer und Kündigungsfrist.",
            "Bei wem bin ich versichert und wann kann ich meine Verträge kündigen? Gib mir bitte die Übersicht aller Policen.",
        ):
            result, message = freetext_turn(router, question, invoke)
            assert successful(result) == expected_mode
            assert message == result["content"][0]["text"] and "3 belegte Verträge" in message

        for question in (
            "Zeige mir nur meine Hausratversicherungen aus dem Jahr 2024.",
            "Wie viel ist sieben plus fünf?",
        ):
            result, message = freetext_turn(router, question, invoke)
            assert result is None and "keinem Vauldy-Recherchewerkzeug" in message
        assert calls == 2, "Unrelated or narrower request accessed the inventory"

        atomic_json(profile, grant | {"enabled": False})
        result, message = freetext_turn(
            router, "Erstelle mir eine Übersicht über alle meine Versicherungspolicen und ihre Kündigungsfristen.", invoke
        )
        failed(result, "mcp-denied-or-stale")
        assert "keine Dokumentzeilen" in message and calls == 3
        atomic_json(profile, grant)
        return {"successfulTurns": 2, "noToolTurns": 2, "revokedTurns": 1, "actualToolCalls": calls}
    finally:
        host.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    path = lambda value: Path(value).resolve()
    parser.add_argument("bridge", type=path)
    parser.add_argument("server", type=path)
    parser.add_argument("--planner", type=path)
    parser.add_argument("--codex", type=path)
    parser.add_argument("--router", type=path, help="Native local chat model for free-text tool selection")
    parser.add_argument("--require-network-denied", action="store_true")
    args = parser.parse_args()
    if args.router and not args.codex:
        parser.error("--router requires --codex")
    if args.require_network_denied:
        check_network_denied()

    with tempfile.TemporaryDirectory(prefix="vauldy-research-chat-") as temp:
        root = Path(temp)
        vault, profile, _, grant = fixture(root)
        original_vault, original_grant = vault.read_bytes(), profile.read_bytes()
        model = wire_check(root, args.bridge, args.server, profile, grant, args.planner)
        profile.write_bytes(original_grant)
        freetext = None
        if args.codex:
            freetext = codex_check(root, args.codex, args.bridge, args.server, profile, grant, args.planner, args.router)
            profile.write_bytes(original_grant)
        assert vault.read_bytes() == original_vault and profile.read_bytes() == original_grant
    print(json.dumps({"stdio": True, "codexToolCall": bool(args.codex), "planner": model, "freetext": freetext,
                      "networkDenied": args.require_network_denied, "passed": [
                          "table-and-source-references", "fixed-tool-parameters", "busy",
                          "cancellation-no-response", "revocation", "timeout", "synthetic-source-unchanged",
                      ]}))


if __name__ == "__main__":
    main()
