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
import argparse, base64, json, os, subprocess, sys, time, urllib.request, urllib.error
from pathlib import Path

SERVE = os.environ.get("DOCLING_SERVE_URL", "http://127.0.0.1:3108")
HOME = Path.home()

def slug(rel: Path) -> str:
    """DriveThruRPG/Foo/Bar Baz.pdf -> DriveThruRPG__Foo__Bar_Baz (flat, unique)."""
    s = str(rel.with_suffix(""))
    for ch in "/ ":
        s = s.replace(ch, "__" if ch == "/" else "_")
    return s

def mem_available_gb() -> float:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 2**20
    return 99.0

def wait_for_headroom(min_gb: float, deadline: float):
    """Block until MemAvailable >= min_gb (the box also runs strata at
    ~60 GB RSS; never let the batch push it into swap)."""
    while mem_available_gb() < min_gb:
        if time.time() > deadline:
            raise RuntimeError(f"no RAM headroom ({min_gb} GB) after waiting")
        time.sleep(20)

def convert(path: Path, timeout: int, min_gb: float):
    wait_for_headroom(min_gb, time.time() + timeout)
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
    ap.add_argument("--no-fallback", action="store_true",
                    help="skip the markitdown fallback pass for docling failures")
    ap.add_argument("--jobs", type=int, default=1,
                    help="concurrent conversions (match DOCLING_SERVE_ENG_LOC_NUM_WORKERS)")
    ap.add_argument("--min-ram-gb", type=float, default=12.0,
                    help="pause conversions while MemAvailable is below this")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--timeout", type=int, default=3600,
                    help="client wait per file; keep >= DOCLING_SERVE_MAX_SYNC_WAIT (3600)")
    a = ap.parse_args()
    srcs = [Path(s) for s in (a.src or [HOME / "Documents/DriveThruRPG"])]
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    state_path = out / ".docling-batch-state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {"done": {}, "failed": {}}

    pdfs = []
    for s in srcs:
        for p in sorted(s.rglob("*.pdf")):
            if p.name.startswith("._") or p.name.startswith("."):
                continue   # AppleDouble junk from the DriveThruRPG sync
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
    import threading
    from concurrent.futures import ThreadPoolExecutor
    lock = threading.Lock()

    def one(i, p, md):
        nonlocal ok, fail
        key = str(p)
        try:
            text = convert(p, a.timeout, a.min_ram_gb)
            md.write_text(text)
            with lock:
                state["done"][key] = {"out": str(md), "chars": len(text), "tool": "docling"}
                state["failed"].pop(key, None)
                ok += 1
                state_path.write_text(json.dumps(state, indent=1))
            print(f"[{i}/{len(todo)}] ok  {p.name} -> {md.name} ({len(text)} chars, "
                  f"{time.time()-t0:.0f}s elapsed)", flush=True)
        except Exception as e:
            with lock:
                state["failed"][key] = {"error": str(e)[:300], "at": time.strftime("%F %T")}
                fail += 1
                state_path.write_text(json.dumps(state, indent=1))
            print(f"[{i}/{len(todo)}] FAIL {p.name}: {e}", flush=True)

    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        list(ex.map(lambda t: one(*t), [(i, p, md) for i, (p, md) in enumerate(todo, 1)]))

    # Fallback tier: docling failures -> markitdown (host CLI, plain text
    # extraction; no layout/tables, but better than a missing document).
    # Files that stay failed after both tools are the marker candidates.
    retry = [(p, md) for p, md in todo if str(p) in state["failed"]]
    if retry and not a.no_fallback:
        print(f"docling-batch: fallback pass with markitdown for {len(retry)} files", flush=True)
        import shutil
        mk = shutil.which("markitdown")
        for p, md in retry:
            key = str(p)
            if not mk:
                state["failed"][key]["fallback"] = "markitdown not installed"
                continue
            try:
                r = subprocess.run([mk, "-o", str(md), str(p)],
                                   capture_output=True, text=True, timeout=600)
                if r.returncode == 0 and md.exists() and md.stat().st_size > 200:
                    state["done"][key] = {"out": str(md), "chars": md.stat().st_size,
                                          "tool": "markitdown"}
                    del state["failed"][key]
                    ok += 1; fail -= 1
                    print(f"  fallback ok  {p.name} ({md.stat().st_size} chars)", flush=True)
                else:
                    state["failed"][key]["fallback"] = (r.stderr or "empty output")[:200]
                    print(f"  fallback FAIL {p.name}", flush=True)
            except Exception as e:
                state["failed"][key]["fallback"] = str(e)[:200]
            state_path.write_text(json.dumps(state, indent=1))

    print(f"docling-batch: done ok={ok} fail={fail} in {time.time()-t0:.0f}s", flush=True)
    return 0 if fail == 0 else 2

if __name__ == "__main__":
    sys.exit(main())
