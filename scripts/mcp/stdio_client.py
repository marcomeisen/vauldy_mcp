"""Local MCP stdio client shared by protocol checks and research tools."""
import json
import os
import selectors
import subprocess
import time


class MCPTransportError(RuntimeError):
    pass


class Client:
    def __init__(self, binary, profile, stderr=subprocess.DEVNULL, capabilities=None, *,
                 protocol_version="2025-11-25", server_options=(), timeout=15,
                 client_name="independent-wire-test"):
        self.process = subprocess.Popen(
            [str(binary), "--profile", str(profile), *server_options],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
        )
        self.counter = 0
        self.pending = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.initialization = self.request("initialize", {
                "protocolVersion": protocol_version,
                "capabilities": capabilities or {},
                "clientInfo": {"name": client_name, "version": "1"},
            }, timeout=timeout)
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except BaseException:
            self.close(abort=True)
            raise

    def send(self, obj):
        self.process.stdin.write(json.dumps(obj).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params, *, timeout=15):
        deadline = time.monotonic() + timeout
        self.counter += 1
        self.send({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params})
        while time.monotonic() < deadline:
            if b"\n" not in self.pending:
                if not self.selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(self.process.stdout.fileno(), 65_536)
                if not chunk:
                    raise MCPTransportError("Server exited before response")
                self.pending += chunk
                if len(self.pending) > 1_500_000:
                    raise MCPTransportError("Oversized MCP response")
                continue
            line, self.pending = self.pending.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == self.counter:
                if "error" in response or "result" not in response:
                    raise MCPTransportError("MCP request failed")
                return response["result"]
        raise TimeoutError("MCP request timed out")

    def call(self, name, **arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self, *, abort=False):
        self.selector.close()
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            if abort and self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        finally:
            self.process.stdout.close()
