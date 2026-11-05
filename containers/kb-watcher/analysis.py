#!/usr/bin/env python3
"""kb-analysis: deterministic state/plumbing side of the W1-W4 analysis
pipelines (knowledge-base plan sec.6). n8n hosts the agentic LLM steps and
calls this service; this service owns the queue, verdicts, tags and reports.

Endpoints (ai.network only, no host publish - like the other KB internals):
  GET  /health
  GET  /pairs?budget=N        next unjudged candidate doc pairs (rotating:
                              LightRAG co-occurrence + RAGFlow retrieval
                              high-similarity), persisted in state/queue.sqlite
  POST /record                {pair_id, relation, confidence, claims, provenance}
                              -> verdict stored; on "contradicts": BOTH docs
                              tagged in RAGFlow (meta_fields tags list) + a
                              discrepancies.md row with chunk provenance.
                              Never modifies documents (plan gate).
  GET  /coverage              LightRAG entity inventory x RAGFlow retrieval
                              probes -> ranked gap candidates (W2)
  GET  /stale                 'updates' verdicts x file mtimes -> stale-suspect
                              docs (W3)
  GET  /drift                 per-repo counts/sizes vs previous manifest
                              snapshot (W4)
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import time
import urllib.request
from collections import defaultdict
from datetime import date, datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import httpx

def env(k, d=""):
    return os.environ.get(k, d).strip()

RAGFLOW_URL = env("RAGFLOW_BASE_URL", "http://systemd-ragflow:9380").rstrip("/")
RAGFLOW_KEY = env("RAGFLOW_API_KEY")
LIGHTRAG_URL = env("LIGHTRAG_BASE_URL", "http://systemd-lightrag:9621").rstrip("/")
LR_KEY = env("LIGHTRAG_API_KEY")


def lr_headers():
    return {"X-API-Key": LR_KEY} if LR_KEY else {}
KB = Path(env("KB_STATE_DIR", "/home/px/workspace/github.com/dark5un/ai-lab-quadlets/kb"))
STATE = KB / "state"
REPORTS = KB / "reports"
DB_PATH = STATE / "queue.sqlite"
PORT = int(env("KB_ANALYSIS_PORT", "8090"))
BUDGET_DEFAULT = int(env("W1_PAIR_BUDGET", "100"))

DS_CACHE: dict[str, str] = {}


def rf_headers():
    return {"Authorization": f"Bearer {RAGFLOW_KEY}"}


def datasets() -> dict[str, str]:
    if not DS_CACHE:
        r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets", headers=rf_headers(),
                      params={"page": 1, "page_size": 100}, timeout=30)
        r.raise_for_status()
        DS_CACHE.update({d["name"]: d["id"] for d in r.json()["data"]})
    return DS_CACHE


def db() -> sqlite3.Connection:
    STATE.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB_PATH)
    c.execute("""CREATE TABLE IF NOT EXISTS pairs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_a TEXT, doc_b TEXT, kind TEXT, src TEXT,
        sim REAL, served_at TEXT, judged TEXT, confidence REAL,
        claims TEXT, provenance TEXT,
        UNIQUE(doc_a, doc_b, kind))""")
    c.execute("CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, at TEXT, body TEXT)")
    c.commit()
    return c


def retrieval_pairs(c: sqlite3.Connection, budget: int) -> int:
    """high-similarity cross-document chunk pairs via RAGFlow retrieval over
    each docs-notes/docs-general document's own top text (rotating queue)."""
    added = 0
    seen = {r[0] for r in c.execute("SELECT doc_a||'|'||doc_b FROM pairs").fetchall()}
    for name, ds_id in datasets().items():
        r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                      headers=rf_headers(), params={"page": 1, "page_size": 20}, timeout=30)
        payload = r.json().get("data", [])
        docs = payload.get("docs", []) if isinstance(payload, dict) else payload
        for d in docs:
            if not d.get("chunk_count"):
                continue
            # probe query: the doc's own first-chunk head (content_summary is
            # not exposed on the list endpoint; filenames score too low)
            q = chunk_text(d["id"])[:300]
            if not q:
                continue
            rr = httpx.post(f"{RAGFLOW_URL}/api/v1/retrieval", headers=rf_headers(),
                            json={"question": q, "dataset_ids": [ds_id],
                                  "top_k": 8, "similarity_threshold": 0.25}, timeout=60)
            data = (rr.json() or {}).get("data") or {}
            for ch in (data.get("chunks") or []):
                other = ch.get("document_id")
                if not other or other == d["id"]:
                    continue
                a, b = sorted([d["id"], other])
                key = f"{a}|{b}"
                if key in seen:
                    continue
                seen.add(key)
                c.execute("INSERT OR IGNORE INTO pairs(doc_a,doc_b,kind,src,sim) "
                          "VALUES(?,?,?,?,?)",
                          (a, b, "retrieval", f"{name}:{d['name']}", ch.get("similarity", 0)))
                added += 1
    c.commit()
    return added


def _name_index() -> dict[str, str]:
    """basename -> ragflow doc id (first match); maps LightRAG file_source
    back to RAGFlow documents for co-occurrence pairing.
    RAGFlow auto-renames same-name re-uploads to 'foo(1).ext' while LightRAG
    keeps the ORIGINAL file_source - normalize the ' (N)' suffix off the
    RAGFlow name before indexing (join on ids elsewhere, never names)."""
    idx: dict[str, str] = {}
    for ds_id in datasets().values():
        try:
            r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                          headers=rf_headers(), params={"page": 1, "page_size": 200},
                          timeout=30)
            payload = r.json().get("data", [])
            for d in (payload.get("docs", []) if isinstance(payload, dict) else payload):
                name = d.get("name", "")
                idx.setdefault(name, d["id"])
                base = re.sub(r"\(\d+\)(?=\.\w+$)", "", name)
                if base != name:
                    idx.setdefault(base, d["id"])
        except Exception:
            continue
    return idx


def graph_pairs(c: sqlite3.Connection) -> int:
    """entities linked in >=2 documents from LightRAG (co-occurrence).
    API verified live on 1.5.7: the endpoint is /graphs (NOT /graph - 404);
    node attrs live under properties{} and file_path joins sources with
    <SEP> (also tolerate legacy ;/,-splitting for safety)."""
    added = 0
    try:
        g = httpx.get(f"{LIGHTRAG_URL}/graphs", headers=lr_headers(), params={"label": "*",
                      "max_depth": 1, "max_nodes": 2000}, timeout=120)
        names = _name_index()
        ent_docs: dict[str, set] = defaultdict(set)
        for node in g.json().get("nodes", []):
            props = node.get("properties") or {}
            fp = props.get("file_path") or node.get("file_path") or ""
            srcs = [s.strip() for s in re.split(r"<SEP>|[;,]", fp) if s.strip()]
            key = props.get("entity_id") or node.get("entity_id") or node.get("id") or ""
            for s in srcs:
                doc_id = names.get(Path(s).name)
                if doc_id:
                    ent_docs[key].add(doc_id)
        existing = {(x, y) for x, y in c.execute(
            "SELECT doc_a, doc_b FROM pairs").fetchall()}
        for docs in ent_docs.values():
            ds = sorted(docs)
            for i in range(len(ds)):
                for j in range(i + 1, len(ds)):
                    a, b = ds[i], ds[j]
                    # pair-level dedupe across channels (the unique index is
                    # (doc_a,doc_b,kind) - without this a pair already queued
                    # by the retrieval channel would be judged twice)
                    if (a, b) in existing:
                        continue
                    existing.add((a, b))
                    c.execute("INSERT OR IGNORE INTO pairs(doc_a,doc_b,kind,src,sim) "
                              "VALUES(?,?,?,?,?)", (a, b, "graph", "co-occurrence", 0.9))
                    added += c.execute("SELECT changes()").fetchone()[0]
    except Exception as e:
        print(f"~ graph pairs: {e}", file=sys.stderr)
    c.commit()
    return added


def serve_pairs(budget: int) -> list[dict]:
    c = db()
    graph_pairs(c)
    retrieval_pairs(c, budget)
    rows = c.execute("""SELECT id,doc_a,doc_b,kind,sim FROM pairs
                        WHERE judged IS NULL ORDER BY sim DESC LIMIT ?""",
                     (budget,)).fetchall()
    now = datetime.now(timezone.utc).isoformat()
    out = []
    for pid, a, b, kind, sim in rows:
        c.execute("UPDATE pairs SET served_at=? WHERE id=?", (now, pid))
        out.append({"pair_id": pid, "doc_a": a, "doc_b": b, "kind": kind, "sim": sim})
    c.commit()
    return out


def chunk_text(doc_id: str) -> str:
    """first chunks of a doc (for proposition extraction)."""
    for ds_id in datasets().values():
        try:
            r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents/{doc_id}/chunks",
                          headers=rf_headers(), params={"page": 1, "page_size": 3}, timeout=30)
            if r.status_code == 200:
                data = r.json().get("data") or {}
                chunks = data.get("chunks") or []
                if chunks:
                    return ("\n\n".join(x.get("content", "")[:1200] for x in chunks))[:3000]
        except Exception:
            continue
    return ""


def doc_name(doc_id: str) -> tuple[str, str | None]:
    for ds_id in datasets().values():
        try:
            r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                          headers=rf_headers(), params={"id": doc_id}, timeout=30)
            payload = r.json().get("data", [])
            docs = payload.get("docs", []) if isinstance(payload, dict) else payload
            if docs:
                return docs[0].get("name", doc_id), ds_id
        except Exception:
            continue
    return doc_id, None


def tag_docs(doc_ids: list[str], topic_slug: str):
    """RAGFlow tags on BOTH implicated docs; meta merge via PATCH (plan gate:
    flags only, never document content edits)."""
    for doc_id in doc_ids:
        name, ds_id = doc_name(doc_id)
        if not ds_id:
            continue
        try:
            r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                          headers=rf_headers(), params={"id": doc_id}, timeout=30)
            payload = r.json().get("data", [])
            docs = payload.get("docs", []) if isinstance(payload, dict) else payload
            meta = (docs[0].get("meta_fields") or {}) if docs else {}
            tags = set(meta.get("tags") or [])
            tags.update({"discrepancy", f"discrepancy:{topic_slug}"})
            meta["tags"] = sorted(tags)
            httpx.patch(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents/{doc_id}",
                        headers=rf_headers(), json={"meta_fields": meta}, timeout=30)
        except Exception as e:
            print(f"~ tag {doc_id}: {e}", file=sys.stderr)


def record(body: dict) -> dict:
    c = db()
    pid = int(body["pair_id"])
    rel = body["relation"]
    c.execute("UPDATE pairs SET judged=?, confidence=?, claims=?, provenance=? WHERE id=?",
              (rel, float(body.get("confidence") or 0),
               json.dumps(body.get("claims") or {}),
               json.dumps(body.get("provenance") or {}), pid))
    row = c.execute("SELECT doc_a,doc_b,kind,sim FROM pairs WHERE id=?", (pid,)).fetchone()
    stored = {"status": "stored"}
    if rel == "contradicts" and row:
        a, b, _kind, sim = row
        slug = re.sub(r"[^a-z0-9]+", "-", str(body.get("topic", "pair"))).strip("-")[:40]
        tag_docs([a, b], slug)
        na, _ = doc_name(a)
        nb, _ = doc_name(b)
        rep = REPORTS / "discrepancies.md"
        rep.parent.mkdir(parents=True, exist_ok=True)
        if not rep.exists():
            rep.write_text("# Discrepancies (W1)\n\nRows carry chunk provenance for "
                           "human verification. Documents are never modified.\n\n")
        claims = body.get("claims") or {}
        with rep.open("a") as f:
            f.write(f"\n## {date.today().isoformat()} — pair {pid} (sim {sim:.3f})\n\n")
            f.write(f"- doc A: `{na}` — claim: {claims.get('a','?')}\n")
            f.write(f"- doc B: `{nb}` — claim: {claims.get('b','?')}\n")
            f.write(f"- verdict: contradicts (confidence {body.get('confidence')})\n")
            f.write(f"- provenance: {json.dumps(body.get('provenance') or {})}\n")
        stored["tagged"] = [a, b]
    c.commit()
    return stored


def coverage() -> dict:
    """W2: entity inventory (LightRAG) x doc counts + retrieval probes."""
    gaps = []
    try:
        g = httpx.get(f"{LIGHTRAG_URL}/graphs", headers=lr_headers(), params={"label": "*", "max_depth": 1,
                      "max_nodes": 3000}, timeout=180)
        for node in g.json().get("nodes", []):
            props = node.get("properties") or {}
            ent = props.get("entity_id") or node.get("entity_id") or node.get("id") or ""
            if not ent or ent == "*":
                continue
            fp = props.get("file_path") or node.get("file_path") or ""
            srcs = [s.strip() for s in re.split(r"<SEP>|[;,]", fp) if s.strip()]
            if len(srcs) <= 1:
                gaps.append({"entity": ent, "docs": len(srcs), "probe": None,
                             "why": "isolated (single source)"})
                continue
            probe = ""
            try:
                r = httpx.post(f"{RAGFLOW_URL}/api/v1/retrieval", headers=rf_headers(),
                               json={"question": f"what does the corpus say about {ent}",
                                     "dataset_ids": list(datasets().values()),
                                     "top_k": 3, "similarity_threshold": 0.0}, timeout=60)
                ch = ((r.json() or {}).get("data") or {}).get("chunks") or []
                probe = max((x.get("similarity") or 0) for x in ch) if ch else 0.0
            except Exception:
                probe = -1
            if probe >= 0 and probe < 0.30:
                gaps.append({"entity": ent, "docs": len(srcs), "probe": probe,
                             "why": "low retrieval confidence"})
    except Exception as e:
        return {"error": str(e)[:200], "gaps": []}
    gaps.sort(key=lambda g: (g["probe"] if g["probe"] is not None else 9))
    try:
        rep = REPORTS / "gaps.md"
        rep.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Gaps (W2) — {datetime.now(timezone.utc).isoformat()}\n",
                 "| entity | sources | probe | why |\n|---|---|---|---|"]
        lines += [f"| {g['entity']} | {g['docs']} | {g['probe']} | {g['why']} |"
                  for g in gaps[:200]]
        rep.write_text("\n".join(lines) + "\n")
    except Exception:
        pass
    return {"gaps": gaps[:200]}


def stale() -> dict:
    """W3: chains of 'updates' verdicts -> oldest doc gets stale-suspect."""
    c = db()
    rows = c.execute("SELECT doc_a,doc_b FROM pairs WHERE judged='updates'").fetchall()
    chain_a = {r[0] for r in rows}
    result = []
    for doc_id in chain_a:  # doc_a holds the older claim in our extraction order
        name, ds_id = doc_name(doc_id)
        if not ds_id:
            continue
        try:
            r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                          headers=rf_headers(), params={"id": doc_id}, timeout=30)
            payload = r.json().get("data", [])
            docs = payload.get("docs", []) if isinstance(payload, dict) else payload
            meta = (docs[0].get("meta_fields") or {}) if docs else {}
            tags = set(meta.get("tags") or [])
            tags.add("stale-suspect")
            meta["tags"] = sorted(tags)
            httpx.patch(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents/{doc_id}",
                        headers=rf_headers(), json={"meta_fields": meta}, timeout=30)
            result.append({"doc": name, "id": doc_id})
        except Exception as e:
            print(f"~ stale {doc_id}: {e}", file=sys.stderr)
    try:
        rep = REPORTS / "stale.md"
        rep.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Stale suspects (W3) — {datetime.now(timezone.utc).isoformat()}",
                 "", "Oldest doc in an `updates` chain, tagged `stale-suspect`:", ""]
        lines += [f"- `{s['doc']}` (id {s['id']})" for s in result] or ["- none"]
        rep.write_text("\n".join(lines) + "\n")
    except Exception:
        pass
    return {"stale_suspects": result}


def drift() -> dict:
    """W4: per-repo doc count/size deltas vs previous manifest snapshot."""
    man_path = KB / "manifest.json"
    snap = STATE / "manifest-prev.json"
    if not man_path.exists():
        return {"error": "no manifest yet"}
    cur = json.loads(man_path.read_text())["files"]
    prev = json.loads(snap.read_text()) if snap.exists() else {}
    def agg(files):
        a = defaultdict(lambda: {"docs": 0, "bytes": 0})
        for p, v in files.items():
            parts = Path(p).parts
            repo = "/".join(parts[:6]) if len(parts) > 5 else parts[0]
            a[repo]["docs"] += 1
            a[repo]["bytes"] += v.get("size", 0)
        return a
    ca, pa = agg(cur), agg(prev)
    rows = []
    for repo in sorted(set(ca) | set(pa)):
        n, o = ca.get(repo, {"docs": 0, "bytes": 0}), pa.get(repo, {"docs": 0, "bytes": 0})
        if (n["docs"], n["bytes"]) != (o["docs"], o["bytes"]):
            rows.append({"repo": repo, "docs": n["docs"], "prev": o["docs"],
                         "kb": round(n["bytes"] / 1024), "prev_kb": round(o["bytes"] / 1024)})
    snap.write_text(json.dumps(cur))
    try:
        rep = REPORTS / "drift.md"
        rep.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Corpus drift (W4) — {datetime.now(timezone.utc).isoformat()}",
                 "", "| repo | docs | prev | KB | prev KB |", "|---|---|---|---|---|"]
        lines += [f"| {r['repo']} | {r['docs']} | {r['prev']} | {r['kb']} | {r['prev_kb']} |"
                  for r in rows[:300]]
        rep.write_text("\n".join(lines) + "\n")
    except Exception:
        pass
    return {"deltas": rows}


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/health":
                return self._send(200, {"status": "ok"})
            if u.path == "/pairs":
                b = int(q.get("budget", [BUDGET_DEFAULT])[0])
                pairs = serve_pairs(b)
                for p in pairs:
                    p["text_a"] = chunk_text(p["doc_a"])
                    p["text_b"] = chunk_text(p["doc_b"])
                return self._send(200, {"pairs": pairs})
            if u.path == "/coverage":
                return self._send(200, coverage())
            if u.path == "/stale":
                return self._send(200, stale())
            if u.path == "/drift":
                return self._send(200, drift())
            if u.path == "/verdicts":
                c = db()
                rows = c.execute("SELECT id,doc_a,doc_b,kind,sim,judged,confidence "
                                 "FROM pairs WHERE judged IS NOT NULL "
                                 "ORDER BY id DESC LIMIT 500").fetchall()
                return self._send(200, {"verdicts": [dict(zip(
                    ["id", "doc_a", "doc_b", "kind", "sim", "judged", "confidence"], r))
                    for r in rows]})
            self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(500, {"error": str(e)[:300]})

    def do_POST(self):
        u = urlparse(self.path)
        try:
            if u.path == "/record":
                return self._send(200, record(self._body()))
            self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(500, {"error": str(e)[:300]})


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
    else:
        # CLI mode for tests: pairs | coverage | drift | stale | verdicts
        cmd = sys.argv[1] if len(sys.argv) > 1 else "pairs"
        c = db()
        if cmd == "pairs":
            print(json.dumps(serve_pairs(5)[:2], indent=1)[:2000])
        elif cmd == "coverage":
            print(json.dumps(coverage())[:800])
        elif cmd == "drift":
            print(json.dumps(drift())[:800])
        elif cmd == "stale":
            print(json.dumps(stale())[:800])
        else:
            print(__doc__)


if __name__ == "__main__":
    main()
