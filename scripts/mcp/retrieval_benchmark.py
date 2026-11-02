#!/usr/bin/env python3
"""Non-destructive MCP audit; synthetic fixtures only, no installed profiles.

Exit 0 means measurements completed, NOT that quality gates passed.
Use --gate for a failing exit code while any measured requirement is unmet.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/mcp"))
from smoke_test import Client, payload


def document(title, text, day=1, status="indexed"):
    return dict(id=str(uuid.uuid4()), title=title, sourceName=title + ".pdf",
                importedAt=f"2026-01-{day:02d}T00:00:00Z", status=status,
                pageCount=1, ocrText="--- Seite 1 ---\n" + text)


class Fixture:
    def __init__(self, root, binary, documents, allowed=None, source_path=None):
        self.root = root
        root.mkdir()
        self.vault = source_path if source_path is not None else root / "documents.json"
        if source_path is None:
            self.vault.write_text(json.dumps(documents))
        self.before = self.vault.read_bytes()
        self.profile = root / "profile.json"
        self.grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName="Synthetic audit",
                          enabled=True, acknowledgedCloudDisclosure=True,
                          vaultPath=str(self.vault),
                          allowedDocumentIDs=allowed if allowed is not None else [d["id"] for d in documents])
        self.profile.write_text(json.dumps(self.grant))
        self.client = Client(binary, self.profile)

    def close(self):
        self.client.close()
        assert self.before == self.vault.read_bytes(), "MCP mutated fixture archive"

    def read_all(self, handle):
        pages = []
        cursor = None
        seen = set()
        responses = []
        while True:
            args = dict(document=handle)
            if cursor is not None:
                assert cursor not in seen, "cursor cycle"
                seen.add(cursor)
                args["cursor"] = cursor
            result = payload(self.client.call("read_document", **args))
            responses.append(result)
            pages.extend(result["segments"])
            cursor = result.get("nextCursor")
            if not cursor:
                return "\n".join(p["text"] for p in pages), responses
            assert len(responses) < 100, "unbounded paging"


def minimal_pdf(path):
    # An actual PDF with a generic scan filename. This exercises embedded-text
    # ingestion, not raster OCR; raster coverage is the existing import smoke test.
    content = b"BT /F1 18 Tf 50 760 Td (LVM Versicherung) Tj 0 -30 Td (auditmarkerepson) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream"]
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer << /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--local", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--gate", action="store_true")
    parser.add_argument("--p0", action="store_true", help="Evaluate complete text lists and the P0 gate; retain separate P1 gaps")
    args = parser.parse_args()
    binary = args.binary.resolve()
    report = dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  binary_version=subprocess.check_output([str(binary), "--version"], text=True).strip(),
                  fixture="synthetic; no real archive; no model answer evaluation", measurements={}, gates={})
    measurements, gates = report["measurements"], report["gates"]
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="vauldy-quality-audit-") as tmp:
        root = Path(tmp)
        names = ["aster", "birke", "ceder", "distel", "eiche", "fichte", "ginster", "hopfen", "iris", "jasmin", "kiefer"]
        documents = [document("LVM LVM LVM Versicherung " + name,
                              "LVM Versicherung\nauditmarker" + name, i + 2) for i, name in enumerate(names)]
        scan = document("Epson_16062026181402", "LVM Versicherung\nauditmarkerepson")
        documents.append(scan)
        fixture = Fixture(root / "exhaustive", binary, documents)
        try:
            if args.p0:
                page = payload(fixture.client.call("list_documents", query="LVM", pageSize=5))
                total = page["totalCount"]
                hits = list(page["items"])
                list_calls = 1
                while page.get("nextCursor"):
                    assert not page["retrievalComplete"] and page["hasMore"]
                    page = payload(fixture.client.call("list_documents", cursor=page["nextCursor"]))
                    assert page["totalCount"] == total
                    hits.extend(page["items"])
                    list_calls += 1
                assert page["retrievalComplete"] and not page["hasMore"]
                result = dict(hits=hits, totalCount=total)
                measurements["list_calls"] = list_calls
            else:
                result = payload(fixture.client.call("search_documents", query="LVM"))
            returned = set()
            for hit in result["hits"]:
                body, _ = fixture.read_all(hit["document"])
                returned.update(re.findall(r"auditmarker[a-z]+", body))
            measurements["lvm"] = dict(expected_documents=12, returned_documents=len(result["hits"]),
                                       unique_markers=len(returned), set_recall=len(returned) / 12,
                                       set_precision=len(returned) / max(1, len(result["hits"])),
                                       has_total_count="totalCount" in result or "total_count" in result,
                                       has_search_cursor=bool(result.get("nextCursor") or result.get("next_cursor")),
                                       generic_scan_in_initial_results="auditmarkerepson" in returned)
            if args.p0:
                measurements["lvm"]["has_list_cursor"] = list_calls > 1
                measurements["lvm"].pop("has_search_cursor")
                measurements["lvm"]["generic_scan_in_complete_results"] = measurements["lvm"].pop("generic_scan_in_initial_results")
            gates["A_F_exhaustive_set"] = len(returned) == 12 and len(result["hits"]) == 12
            exact = payload(fixture.client.call("search_documents", query="16062026181402"))
            assert len(exact["hits"]) == 1
            body, _ = fixture.read_all(exact["hits"][0]["document"])
            measurements["generic_filename"] = dict(exact_lookup_count=1, readable_lvm_body="LVM" in body,
                                                    search_excerpt=exact["hits"][0]["excerpt"])
            gates["B_generic_filename_lookup"] = "auditmarkerepson" in body
            gates["B_readable_excerpt"] = exact["hits"][0]["excerpt"] != "Kein lesbarer Text verfügbar."
            gates["B_structured_issuer"] = "organization_id" in exact["hits"][0]
        finally:
            fixture.close()

        # Isolate organization confusion from ranking and the top-five limit.
        for label, text in [("substring", "FLVMX auditmarkersubstring"),
                            ("mention", "Aussteller: Andere Versicherung. Vergleich mit LVM. auditmarkermention")]:
            fixture = Fixture(root / label, binary, [document("Vergleich", text)])
            try:
                count = len(payload(fixture.client.call("search_documents", query="LVM"))["hits"])
                measurements[label] = dict(returned=count, issuer_is_lvm=False)
                gates["C_exact_token" if label == "substring" else "C_issuer_filter"] = count == 0
            finally:
                fixture.close()

        allowed = document("Pruefung", "auditmarkerpublic " + "Belegtext ohne private Daten. " * 950)
        denied = document("Privat", "auditmarkerprivate")
        fixture = Fixture(root / "access_paging", binary, [allowed, denied], [allowed["id"]])
        try:
            result = payload(fixture.client.call("search_documents", query="auditmarkerpublic"))
            body, reads = fixture.read_all(result["hits"][0]["document"])
            source = allowed["ocrText"].split("\n", 1)[1]
            # Joining chunks adds newlines, so compare whitespace-normalized text.
            reconstructed = re.sub(r"\s+", "", body)
            original = re.sub(r"\s+", "", source)
            gates["F_content_pagination"] = reconstructed == original and len(reads) > 1
            gates["G_allowlist"] = not payload(fixture.client.call("search_documents", query="auditmarkerprivate"))["hits"]
            gates["G_direct_id_denied"] = fixture.client.call("read_document", document=denied["id"]).get("isError") is True
            measurements["content_paging"] = dict(calls=len(reads), segments=sum(len(r["segments"]) for r in reads),
                                                 lossless=gates["F_content_pagination"])
            fixture.grant["enabled"] = False
            fixture.grant["revision"] = str(uuid.uuid4())
            fixture.profile.write_text(json.dumps(fixture.grant))
            gates["G_revoke"] = fixture.client.call("read_document", document=result["hits"][0]["document"]).get("isError") is True
        finally:
            fixture.close()

        if args.p0:
            pending = document("Wartender Beleg", "", status="imported")
            review = document("LVM Review", "LVM", status="partiallyAnalyzed")
            failed = document("Fehlgeschlagener Beleg", "", status="failed")
            unknown = document("Altbestand", "Quelle"); unknown.pop("pageCount")
            approved = [document("LVM Fertig", "LVM"), pending, review, failed, unknown]
            denied = document("PRIVATECANARY", "PRIVATECANARY")
            fixture = Fixture(root / "coverage", binary, approved + [denied],
                              [d["id"] for d in approved] + [str(uuid.uuid4())])
            try:
                empty = payload(fixture.client.call("list_documents", query="NOHITCANARY"))
                coverage = empty["coverage"]
                gates["P0_empty_result_coverage"] = (not empty["items"] and empty["retrievalComplete"]
                    and not empty["processingComplete"] and "SOURCE_PROCESSING_GAPS" in empty["warnings"])
                gates["P0_coverage_counts"] = (coverage["authorizedDocumentCount"] == 5
                    and coverage["completeSourceDocumentCount"] == 1 and coverage["pendingDocumentCount"] == 1
                    and coverage["failedDocumentCount"] == 1 and coverage["reviewDocumentCount"] == 1
                    and coverage["unknownCoverageDocumentCount"] == 1 and coverage["missingGrantedDocumentCount"] == 1)
                measurements["coverage"] = coverage
                listed = payload(fixture.client.call("list_documents"))
                gates["P0_list_privacy"] = (len(listed["items"]) == 5 and "PRIVATECANARY" not in json.dumps(listed)
                    and all(d["id"] not in json.dumps(listed) for d in approved + [denied]))
            finally:
                fixture.close()
            fixture = Fixture(root / "late_excerpt", binary, [document("Scan", "Einleitung. " * 160
                + "LATEEVIDENCEMARKER 49,99 EUR.\nName: Erika Musterfrau\nE-Mail: erika@example.com")])
            try:
                hit = payload(fixture.client.call("search_documents", query="LATEEVIDENCEMARKER"))["hits"][0]
                gates["P0_late_excerpt"] = ("LATEEVIDENCEMARKER" in hit["excerpt"] and "49,99 EUR" in hit["excerpt"]
                    and "Erika Musterfrau" not in hit["excerpt"] and "erika@example.com" not in hit["excerpt"])
            finally:
                fixture.close()

        if args.local:
            local = args.local.resolve()
            store = root / "import-vault"
            pdf = root / "Epson_16062026181402.pdf"
            minimal_pdf(pdf)
            try:
                imported = subprocess.run([str(local), "import", "--store", str(store), str(pdf)],
                                          capture_output=True, text=True, timeout=120, check=True)
                outcome = json.loads(imported.stdout)[0]
                retained = json.loads((store / "documents.json").read_text())[0]
                fixture = Fixture(root / "import-mcp", binary, [retained], source_path=store / "documents.json")
                try:
                    result = payload(fixture.client.call("search_documents", query="LVM"))
                    body, _ = fixture.read_all(result["hits"][0]["document"])
                    gates["B_import_to_mcp"] = ("LVM" in retained["ocrText"] and "auditmarkerepson" in body
                                               and outcome["state"] == "completed")
                    measurements["import"] = dict(state=outcome["state"], pages=outcome["pageCount"],
                                                   method=retained["localImport"]["pages"][0]["method"],
                                                   issuer_entities=len(retained.get("entities", [])),
                                                   classified_category=retained.get("category"),
                                                   source_contains_raster_images=False)
                finally:
                    fixture.close()
            finally:
                if (store / "store.json").exists():
                    subprocess.run([str(local), "worker-stop", "--store", str(store)],
                                   check=True, capture_output=True, timeout=20)
                    for _ in range(150):
                        status = json.loads(subprocess.check_output([str(local), "worker-status", "--store", str(store)], timeout=15))
                        if not status["running"]:
                            break
                        time.sleep(0.1)
                    else:
                        raise RuntimeError("Test worker did not stop")
    report["unmeasured"] = ["D deadline/version correctness", "E raster CER/WER and difficult-scan quality",
                             "H model resistance to prompt injection", "real archive set recall",
                             "semantic search and structured organization resolution"]
    report["quality_pass"] = all(gates.values())
    if args.p0:
        p0_keys = ["A_F_exhaustive_set", "B_generic_filename_lookup", "B_readable_excerpt", "F_content_pagination",
                   "G_allowlist", "G_direct_id_denied", "G_revoke"] + [k for k in gates if k.startswith("P0_")]
        if args.local:
            p0_keys.append("B_import_to_mcp")
        report["p0_gates"] = {key: gates[key] for key in p0_keys}
        report["p0_pass"] = all(report["p0_gates"].values())
    serialized = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(serialized)
    print(serialized, end="")
    return 1 if args.gate and not report.get("p0_pass", report["quality_pass"]) else 0


if __name__ == "__main__":
    sys.exit(main())
