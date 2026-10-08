#!/usr/bin/env python3
"""llama-models.py — per-card llama.cpp model links over the Hugging Face cache.

Layout (docs: README "Models"):
  library   ~/.cache/huggingface/hub            one copy, downloaded by `hf download`
  per card  ~/.local/share/llama.cpp/cards/<card>/<name>/<file>.gguf
            HARDLINKS to the library's real blob files; each llama-cpp-<card>
            unit mounts only its own cards/<card> dir at /models.

The llama.cpp router lists one model per subdir of /models (id = dir name;
split parts -00001-of-0000N must sit side by side in that subdir) and one per
top-level .gguf; this tool only ever writes the subdir form.

  llama-models.py link   <repo> <glob> --card C[,C] [--name N]
  llama-models.py unlink <name> --card C[,C]
  llama-models.py list   [--json]

Paths come from HF_HUB_CACHE (default ~/.cache/huggingface/hub) and
LLAMA_CARDS_DIR (default ~/.local/share/llama.cpp/cards), so the test suite
can point them at a fake tree.
"""
import argparse
import fnmatch
import json
import os
import re
import shutil
import sys

CARDS = ("5090", "4070ti", "both")
SPLIT = re.compile(r"-\d{5}-of-\d{5}$")
NAME_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def hub_dir():
    return os.environ.get("HF_HUB_CACHE") or os.path.join(
        os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface")), "hub")


def cards_dir():
    return os.environ.get("LLAMA_CARDS_DIR", os.path.expanduser("~/.local/share/llama.cpp/cards"))


class Err(Exception):
    pass


def parse_cards(spec):
    out = []
    for c in spec.split(","):
        c = c.strip()
        if c not in CARDS:
            raise Err(f"unknown card '{c}' (5090 | 4070ti | both, comma-separated)")
        if c not in out:
            out.append(c)
    return out


def snapshot_dir(repo):
    """The snapshot dir `hf download` filled for <repo> at refs/main."""
    base = os.path.join(hub_dir(), "models--" + repo.replace("/", "--"))
    ref = os.path.join(base, "refs", "main")
    if not os.path.isfile(ref):
        raise Err(f"{repo} is not in the HF cache ({base}); run `hf download` first")
    rev = open(ref).read().strip()
    snap = os.path.join(base, "snapshots", rev)
    if not os.path.isdir(snap):
        raise Err(f"snapshot {rev} of {repo} missing in the HF cache")
    return snap


def model_stem(path):
    stem = os.path.basename(path)[:-len(".gguf")]
    return SPLIT.sub("", stem)


def match_files(repo, pattern):
    """gguf files in the snapshot whose path relative to it matches <pattern>,
    grouped by model: {name: [snapshot paths]}. mmproj* projector files are
    attached to every model of the same match (vision models)."""
    snap = snapshot_dir(repo)
    hits = []
    for root, _dirs, files in os.walk(snap):
        for f in files:
            if not f.endswith(".gguf"):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, snap)
            if fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(f, pattern):
                hits.append(p)
    groups, projectors = {}, []
    for p in sorted(hits):
        if os.path.basename(p).lower().startswith("mmproj"):
            projectors.append(p)
        else:
            groups.setdefault(model_stem(p), []).append(p)
    if not groups:
        raise Err(f"no .gguf in the cached {repo} matches '{pattern}'")
    for name in groups:
        groups[name] += projectors
    return groups


def link(repo, pattern, cards, name=None):
    groups = match_files(repo, pattern)
    if name:
        if len(groups) != 1:
            raise Err(f"--name needs exactly one model, '{pattern}' matches {len(groups)}: "
                      + ", ".join(sorted(groups)))
        groups = {name: next(iter(groups.values()))}
    done = []
    for mname, files in sorted(groups.items()):
        if not NAME_OK.match(mname):
            raise Err(f"bad model name '{mname}'")
        for card in cards:
            d = os.path.join(cards_dir(), card, mname)
            os.makedirs(d, exist_ok=True)
            for src in files:
                real = os.path.realpath(src)    # never link the snapshot symlink
                dst = os.path.join(d, os.path.basename(src))
                if os.path.lexists(dst):
                    if os.path.samefile(dst, real):
                        continue
                    raise Err(f"{dst} exists and is a different file; unlink {mname} first")
                os.link(real, dst)
            done.append((card, mname))
    return done


def unlink(name, cards):
    if not NAME_OK.match(name):
        raise Err(f"bad model name '{name}'")
    gone = []
    for card in cards:
        d = os.path.join(cards_dir(), card, name)
        if os.path.isdir(d):
            shutil.rmtree(d)    # only hardlinks live here; the HF cache keeps the data
            gone.append(card)
    if not gone:
        raise Err(f"'{name}' is not linked on {', '.join(cards)}")
    return gone


def inventory():
    """{cards: {card: [{name, files, bytes}]}, library: [{repo, file, bytes, cards}]}"""
    by_inode = {}
    out = {"cards": {}, "library": []}
    for card in CARDS:
        root = os.path.join(cards_dir(), card)
        models = []
        if os.path.isdir(root):
            for m in sorted(os.listdir(root)):
                d = os.path.join(root, m)
                if not os.path.isdir(d):
                    continue
                files = sorted(f for f in os.listdir(d) if f.endswith(".gguf"))
                size = 0
                for f in files:
                    st = os.stat(os.path.join(d, f))
                    size += st.st_size
                    by_inode.setdefault((st.st_dev, st.st_ino), set()).add(card)
                models.append({"name": m, "files": files, "bytes": size})
        out["cards"][card] = models
    hub = hub_dir()
    if os.path.isdir(hub):
        for repo_dir in sorted(os.listdir(hub)):
            if not repo_dir.startswith("models--"):
                continue
            repo = repo_dir[len("models--"):].replace("--", "/")
            snaps = os.path.join(hub, repo_dir, "snapshots")
            for root, _d, files in os.walk(snaps):
                for f in sorted(files):
                    if not f.endswith(".gguf"):
                        continue
                    p = os.path.join(root, f)
                    try:
                        st = os.stat(p)
                    except FileNotFoundError:
                        continue
                    out["library"].append({
                        "repo": repo, "file": os.path.relpath(p, snaps).split(os.sep, 1)[-1],
                        "bytes": st.st_size, "links": st.st_nlink - 1,
                        "cards": sorted(by_inode.get((st.st_dev, st.st_ino), ()))})
    return out


def human(n):
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("link")
    a.add_argument("repo")
    a.add_argument("pattern")
    a.add_argument("--card", required=True)
    a.add_argument("--name")
    u = sub.add_parser("unlink")
    u.add_argument("name")
    u.add_argument("--card", required=True)
    li = sub.add_parser("list")
    li.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "link":
            for card, name in link(args.repo, args.pattern, parse_cards(args.card), args.name):
                print(f"  linked {name} -> cards/{card}/{name}/")
        elif args.cmd == "unlink":
            for card in unlink(args.name, parse_cards(args.card)):
                print(f"  unlinked {args.name} from cards/{card}/")
        else:
            inv = inventory()
            if args.json:
                print(json.dumps(inv, indent=1))
                return 0
            for card in CARDS:
                models = inv["cards"][card]
                print(f"llama-cpp-{card}  ({os.path.join(cards_dir(), card)})")
                for m in models:
                    print(f"  {m['name']:<48} {human(m['bytes']):>8}  {len(m['files'])} file(s)")
                if not models:
                    print("  (no models)")
            print(f"\nlibrary  ({hub_dir()})")
            for f in inv["library"]:
                where = ",".join(f["cards"]) or "-"
                print(f"  {f['repo'] + '/' + f['file']:<72} {human(f['bytes']):>8}  cards: {where}")
            if not inv["library"]:
                print("  (empty)")
    except Err as e:
        print(f"llama-models: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
