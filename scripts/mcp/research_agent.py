#!/usr/bin/env python3
"""Local, bounded research pilot for the insurance inventory chat request."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import signal
import subprocess
import time

from stdio_client import Client, MCPTransportError

DEFAULT_REQUEST = "Finde meine Versicherungsverträge und erstelle eine Tabelle mit Versicherer, Vertragsnummer und Kündigungsfrist."
INVENTORY_TERMS = ("versicher", "polic", "pension", "rente")
PLANNED_TERMS = {"police": ("polic", "deckung"), "versicher": ("versicher", "vorsorge")}
PASSAGE_TERMS = "versicherungsschein versicherungsvertrag versicherer vertragsnummer policennummer kündigungsfrist"
CONTRACT_HEADING = re.compile(r"^\s*(?:Versicherungsschein|Versicherungsvertrag)\s*$", re.IGNORECASE)
PSEUDONYM = re.compile(r"\[V_[A-F0-9]{32}_[A-Z_]+_\d+\]")
FIELD_LINES = {
    "insurer": re.compile(r"^\s*Versicherer:\s*(.{1,100}?)\s*$", re.IGNORECASE),
    "policyNumber": re.compile(r"^\s*(?:Vertragsnummer|Policennummer):\s*(.{1,100}?)\s*$", re.IGNORECASE),
    "noticePeriod": re.compile(r"^\s*Kündigungsfrist:\s*(.{1,150}?)\s*$", re.IGNORECASE),
}


class ResearchStopped(Exception):
    """Fixed, source-free reason suitable for a chat response."""


class ResearchSession:
    def __init__(self, client, deadline, max_calls):
        self.client = client
        self.deadline = deadline
        self.max_calls = max_calls
        self.calls = Counter()
        self.evidence_bytes = 0

    def call(self, name, **arguments):
        if self.calls.total() >= self.max_calls:
            raise ResearchStopped("call-limit")
        self.calls[name] += 1
        result = self.client.request(
            "tools/call", {"name": name, "arguments": arguments}, timeout=remaining(self.deadline)
        )
        if result.get("isError"):
            raise ResearchStopped("mcp-denied-or-stale")
        data = result.get("structuredContent")
        if not isinstance(data, dict):
            raise ResearchStopped("invalid-tool-response")
        if name == "read_document":
            self.evidence_bytes += sum(len(segment["text"].encode()) for segment in data.get("segments", []))
        return data

    def pages(self, name, **arguments):
        cursor = None
        seen = set()
        while True:
            params = arguments if cursor is None else {
                key: value for key, value in arguments.items() if key in ("document", "view")
            } | {"cursor": cursor}
            page = self.call(name, **params)
            cursor = page.get("nextCursor")
            if cursor and (not isinstance(cursor, str) or cursor in seen):
                raise ResearchStopped("invalid-pagination")
            if "hasMore" in page and page["hasMore"] != bool(cursor):
                raise ResearchStopped("invalid-pagination")
            if "retrievalComplete" in page and page["retrievalComplete"] != (not cursor):
                raise ResearchStopped("invalid-pagination")
            yield page
            if not cursor:
                return
            seen.add(cursor)

    def inventory(self, query, page_size, max_candidates):
        candidates = {}
        expected = None
        for page in self.pages("list_documents", query=query, matchMode="any-term-substring",
                               pageSize=page_size, includeExcerpts=False):
            if expected is None:
                expected = page["totalCount"]
                if expected > max_candidates:
                    raise ResearchStopped("candidate-limit")
            elif expected != page["totalCount"]:
                raise ResearchStopped("invalid-pagination")
            for item in page["items"]:
                handle = item["document"]
                if handle in candidates:
                    raise ResearchStopped("invalid-pagination")
                candidates[handle] = item["processingStatus"]
        if len(candidates) != expected:
            raise ResearchStopped("invalid-pagination")
        return candidates


def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError()
    return value


def plan(planner, request, deadline):
    if request != DEFAULT_REQUEST:
        raise ResearchStopped("unsupported-request")
    if planner is None:
        return " ".join(INVENTORY_TERMS), "fixed-request"
    result = subprocess.run([str(planner)], input=request, text=True, capture_output=True, timeout=remaining(deadline))
    choice = result.stdout.strip()
    if result.returncode:
        raise ResearchStopped("local-model-unavailable")
    if choice == "unsupported":
        raise ResearchStopped("unsupported-request")
    if choice not in PLANNED_TERMS:
        raise ResearchStopped("invalid-local-plan")
    terms = dict.fromkeys((*PLANNED_TERMS[choice], *INVENTORY_TERMS))
    return " ".join(terms), "apple-on-device"


def evidenced_row(session, handle, mode):
    metadata = [page for page in session.pages("read_document", document=handle, view="metadata")]
    cards = [card for page in metadata for card in page["documents"]]
    if len(cards) != metadata[0]["logicalDocumentCount"]:
        raise ResearchStopped("invalid-pagination")
    if len(cards) > 1:
        return None, "ambiguous-document"
    allowed_pages = set(cards[0]["pages"]) if cards else None
    # The direct reference reads all available content. The agent requests only source windows.
    params = {"view": "content"} if mode == "direct" else {"view": "passages", "query": PASSAGE_TERMS}
    segments = [segment for page in session.pages("read_document", document=handle, **params)
                for segment in page["segments"]]
    fields = {key: {} for key in FIELD_LINES}
    headings = []
    for segment in segments:
        page = segment.get("page")
        if type(page) is not int or page < 1 or (allowed_pages is not None and page not in allowed_pages):
            continue
        source = f"[Quelle:{handle}:S.{page}]"
        if segment.get("source") != source:
            raise ResearchStopped("invalid-source-reference")
        for line in segment["text"].splitlines():
            if CONTRACT_HEADING.fullmatch(line):
                headings.append({"page": page, "source": source, "quote": line.strip()})
            for key, pattern in FIELD_LINES.items():
                match = pattern.fullmatch(line)
                if match and match[1].strip():
                    add_field(fields[key], match[1].strip(), line.strip(), page, source)
        if cards:
            for field in cards[0]["fields"]:
                if (field["role"] == "issuer" and field["page"] == page and field["source"] == source
                        and field["quote"] and field["quote"] in segment["text"] and field["value"] in field["quote"]):
                    add_field(fields["insurer"], field["value"], field["quote"], page, source)

    if not headings:
        return None, "unconfirmed-text-candidate"
    if len(headings) != 1:
        return None, "ambiguous-document"
    row = {"contractEvidence": headings[0], "fields": {}}
    for key, values in fields.items():
        evidence = list(values.values())
        if len(evidence) == 1:
            status = "redacted" if PSEUDONYM.search(evidence[0]["value"]) else "evidenced"
            row["fields"][key] = {"status": status, **evidence[0]}
        elif evidence:
            row["fields"][key] = {"status": "conflicting", "evidence": evidence}
        else:
            row["fields"][key] = {"status": "not-evidenced"}
    return row, None


def add_field(values, value, quote, page, source):
    key = " ".join(value.casefold().split())
    values.setdefault(key, {"value": value, "quote": quote, "page": page, "source": source})


def research(binary, profile, *, mode="agent", planner=None, request=DEFAULT_REQUEST, seconds=60,
             max_calls=300, max_candidates=60, page_size=20):
    started = time.monotonic()
    deadline = started + seconds
    client = session = None
    planner_kind = "none"
    finished = False
    try:
        if not (0 < seconds <= 300 and 1 <= max_calls <= 1000 and 1 <= max_candidates <= 100
                and 1 <= page_size <= 100 and 0 < len(request.encode()) <= 2_000):
            raise ResearchStopped("invalid-request")
        query, planner_kind = plan(planner, request, deadline)
        client = Client(binary, profile, timeout=remaining(deadline), client_name="vauldy-research-pilot")
        session = ResearchSession(client, deadline, max_calls)
        status = session.call("get_vault_status")
        if status["access"] != "explicit-document-grants" or not status["available"]:
            raise ResearchStopped("mcp-denied-or-stale")
        candidates = session.inventory(query, page_size, max_candidates)
        rows = []
        excluded = Counter()
        for handle, processing in candidates.items():
            if processing in ("pending", "failed"):
                excluded["source-not-searchable"] += 1
                continue
            row, reason = evidenced_row(session, handle, mode)
            if row is not None:
                rows.append(row)
            else:
                excluded[reason] += 1

        latest = session.call("get_vault_status")
        if latest != status:
            raise ResearchStopped("mcp-denied-or-stale")
        # A fresh complete inventory reissues or rejects handles for changed sources/grants.
        # Verify even excluded candidates, which also influenced the report.
        if session.inventory(query, page_size, max_candidates) != candidates:
            raise ResearchStopped("mcp-denied-or-stale")
        remaining(deadline)
        finished = True
        report = {"status": "complete", "inventoryComplete": True, "candidateCount": len(candidates),
                  "processingComplete": status["processingComplete"], "coverage": status["coverage"],
                  "excluded": dict(excluded), "rows": rows}
    except KeyboardInterrupt:
        report = stopped("cancelled")
    except (TimeoutError, subprocess.TimeoutExpired):
        report = stopped("timeout")
    except ResearchStopped as error:
        report = stopped(str(error))
    except (OSError, MCPTransportError, TypeError, KeyError, ValueError):
        report = stopped("local-service-error")
    finally:
        if client is not None:
            client.close(abort=not finished)

    return report | {"mode": mode, "planner": planner_kind, "metrics": {
        "elapsedMS": round((time.monotonic() - started) * 1000),
        "calls": dict(session.calls) if session else {},
        "sourceTextBytes": session.evidence_bytes if session else 0,
    }}


def stopped(reason):
    return {"status": "incomplete", "reason": reason, "inventoryComplete": False, "rows": []}


def main():
    signal.signal(signal.SIGINT, signal.default_int_handler)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda path: Path(path).resolve())
    parser.add_argument("--profile", required=True, type=lambda path: Path(path).absolute())
    parser.add_argument("--planner", type=lambda path: Path(path).resolve())
    parser.add_argument("--request", default=DEFAULT_REQUEST)
    parser.add_argument("--mode", choices=("agent", "direct"), default="agent")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    report = research(args.binary, args.profile, mode=args.mode, planner=args.planner,
                      request=args.request, seconds=args.timeout)
    encoded = json.dumps(report, ensure_ascii=False)
    if len(encoded.encode()) > 180_000:
        report = stopped("output-limit")
        encoded = json.dumps(report)
    print(encoded)
    return 0 if report["status"] == "complete" else 2


if __name__ == "__main__":
    raise SystemExit(main())
