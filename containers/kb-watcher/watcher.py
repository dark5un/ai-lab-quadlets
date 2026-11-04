#!/usr/bin/env python3
"""corpus-watcher — nightly incremental ingestion for the KB stack.

Knowledge-base plan ~/tmp/knowledge_base_plan1.md sec.4: walk the corpus
roots, sha256-diff against the manifest, push ONLY added/changed files into
RAGFlow (upload -> parse -> wait), mirror text into LightRAG, tombstone
deletions in both, and write a human-readable run report under kb/reports/.

Runs as a one-shot container (kb-watcher.container + kb-watcher.timer);
stdlib + httpx only. Idempotent: a second pass over an unchanged corpus
processes zero files.

Usage knobs (env or CLI):
  --dry-run          diff only; no writes, no LLM calls
  --limit N          cap processed files this run (budgeting)
  --no-mirror        skip LightRAG mirroring
  --no-classify      skip strata auto-classification
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

import httpx

# ── config ───────────────────────────────────────────────────────────────────
def env(k: str, d: str = "") -> str:
    return os.environ.get(k, d).strip()

RAGFLOW_URL = env("RAGFLOW_BASE_URL", "http://systemd-ragflow:9380").rstrip("/")
RAGFLOW_KEY = env("RAGFLOW_API_KEY")
LIGHTRAG_URL = env("LIGHTRAG_BASE_URL", "http://systemd-lightrag:9621").rstrip("/")
STRATA_URL = env("STRATA_BASE_URL", "http://systemd-strata:8080/v1").rstrip("/")
STRATA_KEY = env("STRATA_API_KEY")
STRATA_MODEL = env("STRATA_MODEL", "qwen3.8-flash-next-iq3_s")
ROOTS = [Path(p) for p in (env("CORPUS_ROOT", "/home/px/workspace"),
                           env("CORPUS_ROOT_2", "/home/px/Documents")) if p]
KB = Path(env("KB_STATE_DIR", "/home/px/workspace/github.com/dark5un/ai-lab-quadlets/kb"))
MANIFEST_PATH = KB / "manifest.json"
ERRORS_PATH = KB / "watcher-errors.json"
REPORTS = KB / "reports"
PARSE_TIMEOUT = int(env("PARSE_TIMEOUT", "900"))
MAX_FILE = 128 * 1024 * 1024            # RAGFlow per-file cap (Go line)
MIRROR_TEXT_CAP = 200_000              # chars mirrored into LightRAG per doc
MAX_ATTEMPTS = 3                       # per-doc failures before recording

# allowlist by extension (plan sec.4)
DOC_EXT = {".pdf", ".docx", ".xlsx", ".pptx", ".eml", ".png", ".jpg", ".jpeg"}
TEXT_EXT = {".md", ".txt"}
CODE_EXT = {".py", ".go", ".rs", ".ts", ".js", ".java", ".c", ".cc", ".cpp",
            ".h", ".hpp", ".sh", ".yaml", ".yml", ".json", ".toml", ".html"}
ALLOWED = DOC_EXT | TEXT_EXT | CODE_EXT

# exclude: dir names anywhere; dot-dirs generally (plan: "dot-dirs generally")
EXCLUDE_DIRS = {"node_modules", "dist", "build", "target", "__pycache__",
                "go/pkg/mod", ".workspaces", ".stfolder"}


def dataset_for(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in DOC_EXT:
        return "docs-general"
    if ext in TEXT_EXT:
        return "docs-notes"
    return "docs-code"


def excluded(path: Path, kbignore: list[str]) -> bool:
    rel = str(path)
    parts = path.parts
    for p in parts:
        if p.startswith(".") or p in EXCLUDE_DIRS:
            if not (p.startswith(".kbignore")):
                return True
        # go/pkg/mod appears as a two-part name; handled by substring check below
    if any(seg in rel for seg in ("node_modules/", "/dist/", "/build/", "/target/",
                                  "/go/pkg/mod/", "/__pycache__/", "/.venv/",
                                  "/.workspaces/")):
        return True
    for pat in kbignore:
        if fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(rel, pat.rstrip("/") + "/*"):
            return True
    return False


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ── manifest ─────────────────────────────────────────────────────────────────
def load_manifest() -> dict:
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text())
    return {"files": {}, "last_run": None}


def save_manifest(m: dict) -> None:
    tmp = MANIFEST_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(m, indent=1, sort_keys=True))
    tmp.replace(MANIFEST_PATH)


def load_errors() -> list:
    if ERRORS_PATH.exists():
        return json.loads(ERRORS_PATH.read_text())
    return []


def save_errors(errs: list) -> None:
    ERRORS_PATH.write_text(json.dumps(errs, indent=1))


# ── scan ─────────────────────────────────────────────────────────────────────
def scan() -> dict[str, dict]:
    """path -> {sha256,size} for every allowed, non-excluded file."""
    out: dict[str, dict] = {}
    for root in ROOTS:
        if not root.is_dir():
            continue
        # self-exclusion: the watcher's own kb/ state lives inside a scanned root
        kb_excl = str(KB)
        for dirpath, dirnames, filenames in os.walk(root):
            dp = Path(dirpath)
            if any(part in ("node_modules", ".git", "__pycache__", ".workspaces")
                   for part in dp.parts[len(root.parts):]):
                dirnames[:] = []
                continue
            if str(dp) == kb_excl or str(dp).startswith(kb_excl + os.sep):
                dirnames[:] = []
                continue
            # dot dirs (plan: generally excluded; .git/.venv/... all live here)
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            kbignore = []
            ki = dp / ".kbignore"
            if ki.is_file():
                kbignore = [l.strip() for l in ki.read_text().splitlines()
                            if l.strip() and not l.startswith("#")]
            for fn in filenames:
                p = dp / fn
                if p.suffix.lower() not in ALLOWED:
                    continue
                if excluded(p, kbignore):
                    continue
                try:
                    st = p.stat()
                except OSError:
                    continue
                if st.st_size > MAX_FILE or st.st_size == 0:
                    continue
                try:
                    h = sha256_file(p)
                except OSError as e:
                    print(f"  ! hash {p}: {e}", file=sys.stderr)
                    continue
                out[str(p)] = {"sha256": h, "size": st.st_size}
            _ = dirnames  # walk continues into kept dirs
    return out


# ── strata classification (auto: namespace; never overwrites manual tags) ───
def classify(path: str) -> dict | None:
    if not STRATA_URL or not STRATA_MODEL:
        return None
    head = ""
    try:
        p = Path(path)
        if p.suffix.lower() in TEXT_EXT | CODE_EXT:
            head = p.read_text(errors="replace")[:2000]
    except OSError:
        return None
    prompt = (
        "Classify this file for a personal knowledge base. Reply with STRICT "
        "JSON only: {\"doc_type\": one of [note, docs, code, config, report, "
        "paper, email, other], \"domain\": short topic slug, \"language\": "
        "file language or prose language (en/el/...), \"summary\": <=25 words. "
        f"\nPATH: {path}\nHEAD:\n{head}"
    )
    try:
        r = httpx.post(f"{STRATA_URL}/chat/completions",
                       headers={"Authorization": f"Bearer {STRATA_KEY}"},
                       json={"model": STRATA_MODEL, "temperature": 0,
                             "response_format": {"type": "json_object"},
                             "messages": [{"role": "user", "content": prompt}]},
                       timeout=120)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
        d = json.loads(content)
        return {"auto:doc_type": str(d.get("doc_type", "other"))[:40],
                "auto:domain": str(d.get("domain", ""))[:60],
                "auto:language": str(d.get("language", ""))[:20]}
    except Exception as e:  # classification is best-effort
        print(f"  ~ classify failed {path}: {e}", file=sys.stderr)
        return None


# ── RAGFlow API ──────────────────────────────────────────────────────────────
def rf_headers() -> dict:
    return {"Authorization": f"Bearer {RAGFLOW_KEY}"}


def rf_datasets() -> dict[str, str]:
    """name -> id; creates missing datasets."""
    r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets", headers=rf_headers(),
                  params={"page": 1, "page_size": 100}, timeout=30)
    r.raise_for_status()
    have = {d["name"]: d["id"] for d in r.json().get("data", [])}
    for want in ("docs-general", "docs-code", "docs-notes"):
        if want not in have:
            # RAGFlow 1.0: parse_type/parser_id replace legacy chunk_method
            c = httpx.post(f"{RAGFLOW_URL}/api/v1/datasets", headers=rf_headers(),
                           json={"name": want, "parse_type": 1,
                                 "parser_id": "general"}, timeout=30)
            c.raise_for_status()
            have[want] = c.json()["data"]["id"]
    return have


def rf_upload(ds_id: str, path: str, meta: dict) -> str:
    p = Path(path)
    with p.open("rb") as f:
        files = {"file": (p.name, f, "application/octet-stream")}
        r = httpx.post(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                       headers=rf_headers(), files=files, timeout=300)
    r.raise_for_status()
    payload = r.json()
    if payload.get("code") not in (0, None):
        raise RuntimeError(f"upload rejected: {payload}")
    docs = payload.get("data") or []
    if not docs:
        raise RuntimeError(f"upload returned no document: {payload}")
    doc_id = docs[0]["id"]
    if meta:
        # RAGFlow 1.0 sets per-document meta via PATCH (not on the upload form)
        u = httpx.patch(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents/{doc_id}",
                        headers=rf_headers(), json={"meta_fields": meta},
                        timeout=30)
        if u.status_code >= 400:
            print(f"  ~ meta_fields patch failed for {doc_id}: {u.text[:120]}",
                  file=sys.stderr)
    return doc_id


def rf_parse(ds_id: str, doc_ids: list[str]) -> None:
    # RAGFlow 1.0 parse route (built-in chunking pipeline)
    r = httpx.post(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/chunks",
                   headers=rf_headers(), json={"document_ids": doc_ids},
                   timeout=30)
    r.raise_for_status()
    if r.json().get("code") not in (0, None):
        raise RuntimeError(f"parse rejected: {r.json()}")


def rf_wait(ds_id: str, doc_ids: list[str]) -> dict[str, str]:
    """poll until every doc is DONE/FAIL/CANCEL; returns id->status."""
    deadline = time.monotonic() + PARSE_TIMEOUT
    status = {d: "RUNNING" for d in doc_ids}
    while time.monotonic() < deadline:
        remaining = [d for d, s in status.items() if s == "RUNNING"]
        if not remaining:
            break
        r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents",
                      headers=rf_headers(),
                      params={"id": remaining[0]}, timeout=30)
        r.raise_for_status()
        payload = r.json().get("data", [])
        docs = payload.get("docs", []) if isinstance(payload, dict) else payload
        for d in docs:
            run = str(d.get("run", "")).upper()
            if d.get("id") in status and run in ("DONE", "2", "FAIL", "3",
                                                 "CANCEL", "CANCELED", "4"):
                status[d["id"]] = "DONE" if run in ("DONE", "2") else "FAIL"
        time.sleep(5)
    for d in list(status):
        if status[d] == "RUNNING":
            status[d] = "TIMEOUT"
    return status


def rf_chunks(ds_id: str, doc_id: str) -> str:
    r = httpx.get(f"{RAGFLOW_URL}/api/v1/datasets/{ds_id}/documents/{doc_id}/chunks",
                  headers=rf_headers(), params={"page": 1, "page_size": 50},
                  timeout=60)
    if r.status_code >= 400:
        return ""
    data = r.json().get("data") or {}
    chunks = data.get("chunks") if isinstance(data, dict) else data
    return "\n\n".join(c.get("content", "") for c in (chunks or []))[:MIRROR_TEXT_CAP]


def rf_delete(ds_name: str, doc_ids: list[str], ds: dict[str, str]) -> None:
    """DELETE /api/v1/datasets/{dataset_id}/documents (v0.20+ contract)."""
    if not doc_ids:
        return
    r = httpx.delete(f"{RAGFLOW_URL}/api/v1/datasets/{ds[ds_name]}/documents",
                     headers=rf_headers(), json={"ids": doc_ids}, timeout=60)
    if r.status_code >= 400:
        raise RuntimeError(f"delete failed: {r.status_code} {r.text[:200]}")


# ── LightRAG mirror ──────────────────────────────────────────────────────────
def lr_insert(text: str, file_source: str) -> str | None:
    r = httpx.post(f"{LIGHTRAG_URL}/documents/text",
                   json={"text": text, "file_source": file_source}, timeout=600)
    if r.status_code >= 400:
        raise RuntimeError(f"lightrag insert: {r.status_code} {r.text[:200]}")
    return (r.json() or {}).get("track_id")


def lr_delete_by_source(file_source: str) -> int:
    """LightRAG generates doc ids from the content hash; the stable join key
    is file_path (== our file_source). Scan the paginated listing and delete
    every doc for this source (DELETE /documents/delete_document)."""
    deleted = 0
    page = 1
    while True:
        r = httpx.post(f"{LIGHTRAG_URL}/documents/paginated",
                       json={"page": page, "page_size": 200,
                             "sort_field": "file_path",
                             "sort_direction": "asc"}, timeout=60)
        if r.status_code >= 400:
            raise RuntimeError(f"lightrag paginated: {r.status_code} {r.text[:200]}")
        d = r.json()
        ids = [doc["id"] for doc in d.get("documents", [])
               if doc.get("file_path") == file_source]
        for i in range(0, len(ids), 50):
            dr = httpx.request("DELETE", f"{LIGHTRAG_URL}/documents/delete_document",
                               json={"doc_ids": ids[i:i + 50]}, timeout=120)
            if dr.status_code >= 400:
                raise RuntimeError(f"lightrag delete: {dr.status_code} {dr.text[:200]}")
            deleted += len(ids[i:i + 50])
        if not (d.get("pagination") or {}).get("has_next"):
            break
        page += 1
    return deleted


# ── main ─────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    # per-run ingest budget (first pass over a large corpus must drain
    # gradually across nights, not blow the 6h unit timeout)
    ap.add_argument("--limit", type=int,
                    default=int(os.environ.get("INGEST_LIMIT", "300")))
    ap.add_argument("--no-mirror", action="store_true")
    ap.add_argument("--no-classify", action="store_true")
    args = ap.parse_args()

    if not RAGFLOW_KEY and not args.dry_run:
        print("RAGFLOW_API_KEY empty - run scripts/kb-bootstrap.sh first",
              file=sys.stderr)
        return 2

    t0 = time.monotonic()
    m = load_manifest()
    prev = m["files"]
    cur = scan()
    added = [p for p in cur if p not in prev]
    changed = [p for p in cur if p in prev and cur[p]["sha256"] != prev[p]["sha256"]]
    deleted = [p for p in prev if p not in cur]
    unchanged = len(cur) - len(added) - len(changed)
    print(f"scan: {len(cur)} files | +{len(added)} ~{len(changed)} -{len(deleted)} "
          f"unchanged={unchanged}")

    if args.dry_run:
        return 0

    if args.limit:
        added = added[: args.limit]
        changed = changed[: max(0, args.limit - len(added))]

    ds = rf_datasets()  # name -> id
    errors = load_errors()
    ok = fail = 0
    new_docs: dict[str, tuple[str, str]] = {}  # path -> (ds_id, doc_id)

    # deletions: tombstone both stores first (cheap, keeps counts honest)
    for p in deleted:
        old = prev[p]
        try:
            if old.get("ragflow_id"):
                rf_delete(old["dataset"], [old["ragflow_id"]], ds)
            if not args.no_mirror:
                lr_delete_by_source(p)
            del m["files"][p]
        except Exception as e:
            print(f"  ! delete {p}: {e}", file=sys.stderr)
            errors.append({"path": p, "op": "delete", "err": str(e)[:300],
                           "at": datetime.now(timezone.utc).isoformat()})
            fail += 1

    # uploads (docs pending parse grouped per dataset)
    to_parse: dict[str, list[str]] = {}
    for p in added + changed:
        old = prev.get(p)
        try:
            dsname = dataset_for(Path(p))
            if old and old.get("ragflow_id"):
                try:
                    rf_delete(dsname, [old["ragflow_id"]], ds)
                except Exception:
                    pass  # stale id: RAGFlow keeps the old doc; we just re-add
            meta = {} if args.no_classify else (classify(p) or {})
            meta["path"] = p
            doc_id = rf_upload(ds[dsname], p, meta)
            m["files"][p] = {"sha256": cur[p]["sha256"], "size": cur[p]["size"],
                             "dataset": dsname, "ragflow_id": doc_id,
                             "ingested_at": datetime.now(timezone.utc).isoformat()}
            to_parse.setdefault(ds[dsname], []).append(doc_id)
            new_docs[p] = (ds[dsname], doc_id)
        except Exception as e:
            attempts = (old or {}).get("attempts", 0) + 1
            rec = {"path": p, "op": "upload", "err": str(e)[:300],
                   "attempts": attempts,
                   "at": datetime.now(timezone.utc).isoformat()}
            errors.append(rec)
            if attempts >= MAX_ATTEMPTS:
                print(f"  ! upload FAILED x{attempts} {p}", file=sys.stderr)
            else:
                print(f"  ~ upload attempt {attempts} failed {p}: {e}",
                      file=sys.stderr)
                if old:
                    old["attempts"] = attempts
            fail += 1

    save_manifest(m)  # persist upload results before the slow parse phase

    # parse + wait per dataset, then mirror
    for ds_id, ids in to_parse.items():
        try:
            rf_parse(ds_id, ids)
        except Exception as e:
            errors.append({"op": "parse-batch", "ids": ids, "err": str(e)[:300],
                           "at": datetime.now(timezone.utc).isoformat()})
            fail += 1
            continue
        st = rf_wait(ds_id, ids)
        save_manifest(m)
        for doc_id, s in st.items():
            if s != "DONE":
                errors.append({"op": "parse", "ds": ds_id, "doc": doc_id,
                               "status": s,
                               "at": datetime.now(timezone.utc).isoformat()})
                fail += 1

    if not args.no_mirror:
        for p, (ds_id, doc_id) in new_docs.items():
            ext = Path(p).suffix.lower()
            text = ""
            try:
                if ext in TEXT_EXT | CODE_EXT:
                    text = Path(p).read_text(errors="replace")[:MIRROR_TEXT_CAP]
                else:
                    text = rf_chunks(ds_id, doc_id)
                if text.strip():
                    # changed file: drop the old content-hashed mirror doc first
                    if p in changed:
                        lr_delete_by_source(p)
                    lr_insert(text, p)
            except Exception as e:
                errors.append({"path": p, "op": "mirror", "err": str(e)[:300],
                               "at": datetime.now(timezone.utc).isoformat()})
                fail += 1

    # persist
    m["last_run"] = {"at": datetime.now(timezone.utc).isoformat(),
                     "added": len(added), "changed": len(changed),
                     "deleted": len(deleted), "unchanged": unchanged,
                     "ok": len(new_docs), "fail": fail,
                     "secs": round(time.monotonic() - t0, 1)}
    save_manifest(m)
    save_errors(errors[-500:])

    rep = REPORTS / f"ingest-{date.today().isoformat()}.md"
    rep.parent.mkdir(parents=True, exist_ok=True)
    with rep.open("a") as f:
        f.write(f"\n## run {m['last_run']['at']}\n\n")
        f.write(f"| added | changed | deleted | unchanged | ok | fail | secs |\n")
        f.write(f"|---|---|---|---|---|---|---|\n")
        lr_ = m["last_run"]
        f.write(f"| {lr_['added']} | {lr_['changed']} | {lr_['deleted']} | "
                f"{lr_['unchanged']} | {lr_['ok']} | {lr_['fail']} | {lr_['secs']} |\n")
    print(f"done: ok={len(new_docs)} fail={fail} in "
          f"{m['last_run']['secs']}s; report {rep}")

    # plan sec.6: n8n analysis runs trigger on watcher completion (fallback
    # is the per-workflow cron). Best-effort; never fails the ingest run.
    hook = env("N8N_WEBHOOK_URL")
    if hook and (added or changed or deleted):
        try:
            httpx.post(hook, json={"ok": len(new_docs), "fail": fail,
                                   "at": m["last_run"]["at"]}, timeout=15)
        except Exception as e:
            print(f"  ~ completion webhook failed: {e}", file=sys.stderr)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
