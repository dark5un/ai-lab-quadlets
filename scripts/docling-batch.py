#!/usr/bin/env python3
"""docling-batch.py — convert PDFs under a source tree to markdown via
docling-serve (127.0.0.1:3108) and write them into the rag's watched folder.

Resumable: a file is skipped when its .md output already exists and is
non-empty; failures are recorded in a manifest and retried next run.
Progress goes to stdout (one line per file) and a JSON state file.

  scripts/docling-batch.py [--src DIR]... [--out DIR] [--limit N]
                           [--max-mb MB] [--include-existing] [--dry-run]

Defaults: src ~/Documents/DriveThruRPG, out ~/.local/share/rag-library/docling-out.
Requires docling-serve up (ai-lab docling cpu|4070ti).
"""
import argparse, base64, json, os, sys, time, urllib.request, urllib.error
from pathlib import Path

SERVE = os.environ.get("DOCLING_SERVE_URL", "http://127.0.0.1:3108")
HOME = Path.home()

def slug(rel: Path) -> str:
    """DriveThruRPG/Foo/Bar Baz.pdf -> DriveThruRPG__Foo__Bar_Baz (flat, unique)."""
    s = str(rel.with_suffix(""))
    for ch in "/ ":
        s = s.replace(ch, "__" if ch == "/" else "_")
    return s

def convert(path: Path, timeout: int):
    body = json.dumps({
        "sources": [{"kind": "file",
                     "base64_string": base64.b64encode(path.read_bytes()).decode(),
                     "filename": path.name}],
        "do_ocr": False, "do_table_structure": True,
        "to_formats": ["md"], "image_export_mode": "placeholder",
    }).encode()
    req = urllib.request.Request(f"{SERVE}/v1/convert/source", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    if d.get("status") != "success":
        raise RuntimeError(f"status={d.get('status')} errors={d.get('errors')}")
    md = d["document"].get("md_content", "")
    if not md.strip():
        raise RuntimeError("empty markdown")
    return md

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", action="append", default=None)
    ap.add_argument("--out", default=str(HOME / ".local/share/rag-library/docling-out"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-mb", type=float, default=0, help="skip PDFs larger than this")
    ap.add_argument("--include-existing", action="store_true",
                    help="also convert PDFs already inside the out dir's source scan")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    srcs = [Path(s) for s in (a.src or [HOME / "Documents/DriveThruRPG"])]
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    state_path = out / ".docling-batch-state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {"done": {}, "failed": {}}

    pdfs = []
    for s in srcs:
        for p in sorted(s.rglob("*.pdf")):
            if out in p.parents:
                continue
            if a.max_mb and p.stat().st_size > a.max_mb * 1024 * 1024:
                continue
            pdfs.append((p, s))

    todo = []
    for p, s in pdfs:
        md = out / (slug(p.relative_to(s)) + ".md")
        key = str(p)
        if md.exists() and md.stat().st_size > 200:
            state["done"][key] = {"out": str(md), "skipped_existing": True}
            continue
        todo.append((p, md))
    if a.limit:
        todo = todo[:a.limit]

    print(f"docling-batch: {len(pdfs)} pdfs found, {len(todo)} to convert -> {out}", flush=True)
    if a.dry_run:
        for p, md in todo[:50]:
            print(f"  would convert: {p}")
        return 0

    t0 = time.time(); ok = fail = 0
    for i, (p, md) in enumerate(todo, 1):
        key = str(p)
        try:
            text = convert(p, a.timeout)
            md.write_text(text)
            state["done"][key] = {"out": str(md), "chars": len(text)}
            state["failed"].pop(key, None)
            ok += 1
            print(f"[{i}/{len(todo)}] ok  {p.name} -> {md.name} ({len(text)} chars, "
                  f"{time.time()-t0:.0f}s elapsed)", flush=True)
        except Exception as e:
            fail += 1
            state["failed"][key] = {"error": str(e)[:300], "at": time.strftime("%F %T")}
            print(f"[{i}/{len(todo)}] FAIL {p.name}: {e}", flush=True)
        state_path.write_text(json.dumps(state, indent=1))
    print(f"docling-batch: done ok={ok} fail={fail} in {time.time()-t0:.0f}s", flush=True)
    return 0 if fail == 0 else 2

if __name__ == "__main__":
    sys.exit(main())
