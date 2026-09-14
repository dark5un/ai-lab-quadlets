#!/usr/bin/env python3
"""
refresh-presets.py — Regenerate the per-model section of llama.cpp presets.ini
with HARDWARE-FITTED context sizes, leaving the [*] global block untouched.

KV sizing is validated against live llama-server allocations:
  atom        = 2 * n_head_kv * head_dim * bpe(cache)
  linear_layers = n_layer / interval     (full_attention_interval or sliding_window_pattern)
  KV bytes(ct) = atom * linear_layers * ct   [+ Llama-4 SWA constant]
Checked exact: Qwen3.8 atom=1152B -> 144MiB@8k; Muse atom=288B -> 29.25MiB@8k.

Per-model ctx = min( hardware_max_ctx, n_ctx_train ) capped by a VRAM safety margin
so a loaded model leaves GPU headroom for the desktop.

Usage:
  refresh-presets.py [--models-dir DIR] [--gpu IDX] [--reserve N] [--margin PCT]
                     [--presets FILE] [--write]
  (default: dry-run, prints proposed config)

Model files are grouped by their directory; the largest-Q best quant in each
directory supplies the numbers (or a file given by --model PATH targets one).
"""

import argparse
import glob
import os
import struct
import subprocess
import sys

SZ = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
CACHE_BPE = {"f16": 2.0, "f32": 4.0, "q8_0": 34 / 32, "q4_0": 18 / 32}


# ── GGUF metadata (no deps) ────────────────────────────────────────────────
class GGUF:
    def __init__(self, path):
        self.meta = {}
        with open(path, "rb") as f:
            assert f.read(4) == b"GGUF"
            struct.unpack("<I", f.read(4))
            struct.unpack("<Q", f.read(8))
            nkv = struct.unpack("<Q", f.read(8))[0]
            for _ in range(nkv):
                klen = struct.unpack("<Q", f.read(8))[0]
                key = f.read(klen).decode("utf-8", "replace")
                self.meta[key] = self._val(f)

    def _val(self, f):
        t = struct.unpack("<I", f.read(4))[0]
        if t == 8:
            l = struct.unpack("<Q", f.read(8))[0]
            return f.read(l).decode("utf-8", "replace")
        if t == 9:
            at = struct.unpack("<I", f.read(4))[0]
            cnt = struct.unpack("<Q", f.read(8))[0]
            o = []
            for _ in range(cnt):
                if at == 8:
                    l = struct.unpack("<Q", f.read(8))[0]
                    o.append(f.read(l).decode("utf-8", "replace"))
                else:
                    o.append(self._plain(f, at))
            return o
        return self._plain(f, t)

    def _plain(self, f, t):
        m = {
            0: ("<B", 1),
            1: ("<b", 1),
            2: ("<H", 2),
            3: ("<h", 2),
            4: ("<I", 4),
            5: ("<i", 4),
            6: ("<f", 4),
            7: ("<?", 1),
            10: ("<Q", 8),
            11: ("<q", 8),
            12: ("<d", 8),
        }
        if t in m:
            fmt, sz = m[t]
            return struct.unpack(fmt, f.read(sz))[0]
        raise ValueError(t)


class ModelInfo:
    def __init__(self, path):
        g = GGUF(path)
        self.path = path
        self.meta = g.meta
        self.arch = g.meta.get("general.architecture", "?")
        self.name = g.meta.get("general.name") or os.path.basename(
            os.path.dirname(path)
        )
        self.ft = g.meta.get("general.file_type")
        a = self.arch + "."
        self.n_layer = int(g.meta.get(f"{a}block_count", 0) or 0)
        self.n_head_kv = int(
            g.meta.get(f"{a}attention.head_count_kv", 0)
            or g.meta.get(f"{a}attention.head_count", 0)
            or 0
        )
        self.hd_k = int(
            g.meta.get(f"{a}attention.key_length", 0)
            or g.meta.get(f"{a}attention.head_count", 0)
            or 0
        )
        self.n_ctx_train = int(
            g.meta.get(f"{a}context_length", 0) or g.meta.get(f"{a}ctx_length", 0) or 0
        )
        self.interval = int(g.meta.get(f"{a}full_attention_interval", 0) or 0)
        self.sw_pattern = int(
            g.meta.get(f"{a}attention.sliding_window_pattern", 0) or 0
        )
        self.sw_win = int(g.meta.get(f"{a}attention.sliding_window", 0) or 0)
        crit = self.interval or self.sw_pattern or 1
        self.linear_layers = (self.n_layer // crit) if crit > 1 else self.n_layer
        self.bytes = os.path.getsize(path)

    def atom(self, cache):
        return 2 * self.n_head_kv * self.hd_k * CACHE_BPE[cache]

    def max_ctx(self, cache, vram_mib, reserve_mib):
        atom = self.atom(cache)
        linear_bpt = atom * self.linear_layers
        swa = 0
        if self.sw_pattern > 1 and self.sw_win > 0:
            sl = self.n_layer - self.linear_layers
            if sl > 0:
                swa = sl * atom * self.sw_win
        avail = (vram_mib - reserve_mib) * 1024 * 1024 - self.bytes - swa
        return max(0, int(avail // linear_bpt)) if linear_bpt > 0 else 0


def round_down(ctx):
    return (ctx // 2048) * 2048


def gpu_label(idx=0):
    out = subprocess.run(
        ["nvidia-smi", "-L"], capture_output=True, text=True, check=False
    ).stdout.splitlines()
    if idx < len(out):
        return out[idx].split(":")[0]
    return f"GPU {idx}"


def gpu_vram(idx=0):
    out = (
        subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            check=False,
        )
        .stdout.strip()
        .splitlines()
    )
    return int(out[idx].replace(" MiB", ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--models-dir", default=os.path.expanduser("~/.local/share/llama.cpp/models")
    )
    ap.add_argument("--gpu", type=int, default=0)
    ap.add_argument("--cache", default="q4_0", choices=sorted(CACHE_BPE))
    ap.add_argument(
        "--reserve",
        type=int,
        default=2048,
        help="fixed MiB held back (CUDA ctx, desktop)",
    )
    ap.add_argument(
        "--margin", type=float, default=0.10, help="fraction of max_ctx held back"
    )
    ap.add_argument(
        "--presets",
        default=os.path.expanduser("~/.config/containers/config/llama.cpp/presets.ini"),
    )
    ap.add_argument("--write", action="store_true")
    ap.add_argument(
        "--model", help="target a single gguf path instead of the whole dir"
    )
    args = ap.parse_args()

    vram = gpu_vram(args.gpu)
    gname = gpu_label(args.gpu)
    if args.model:
        files = [args.model]
    else:
        files = sorted(glob.glob(os.path.join(args.models_dir, "*", "*.gguf")))
    if not files:
        sys.exit(f"no .gguf under {args.models_dir}")

    # group by directory, keep best-quant (largest file) per dir as representative
    by_dir = {}
    for p in files:
        d = os.path.dirname(p)
        by_dir.setdefault(d, []).append((os.path.getsize(p), p))
    picks = [max(v)[1] for v in by_dir.values()]

    entries = []
    print(
        f"{gname}  VRAM={vram}MiB reserve={args.reserve}MiB margin={int(args.margin * 100)}%"
    )
    for p in picks:
        mi = ModelInfo(p)
        hard = mi.max_ctx(args.cache, vram, args.reserve)
        if mi.n_ctx_train and mi.n_ctx_train <= hard:
            ctx = round_down(mi.n_ctx_train)  # train-bound: model's native context
            kind = "train-capped"
        else:
            ctx = round_down(
                int(hard * (1 - args.margin))
            )  # vram-bound: leave headroom
            kind = "vram-bound"
        entries.append((mi, ctx, hard, kind))
        print(
            f"  {os.path.basename(os.path.dirname(p)):42s} {mi.name:20s} "
            f"ctx={ctx:>7,} (hardmax={hard:>8,} train={mi.n_ctx_train or '-':,} [{kind}]) "
            f"[{os.path.basename(p)}]"
        )

    # ── build output, preserving [*] ─────────────────────────────────────────
    with open(args.presets) as fh:
        cur = fh.read()
    lines = cur.rstrip().split("\n")
    cut = None
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith(";") and "Per-model overrides" in ln:
            cut = i  # drop this line and everything after
            break
    head = "\n".join(lines[:cut]).rstrip() if cut is not None else cur.rstrip()
    out = head + "\n"
    out += "\n; ─── Per-model overrides (AUTO-REFRESHED by refresh-presets.py) ──\n"
    for mi, ctx, hard, kind in entries:
        rel = os.path.basename(
            os.path.dirname(mi.path)
        )  # models dir name == router alias
        out += f"\n[{rel}]\n"
        out += f"ctx-size = {ctx}\n"
        out += f"; computed: hardmax={hard} train={mi.n_ctx_train or 'n/a'} linear={mi.linear_layers}L atom={mi.atom(args.cache):.0f}B ({args.cache})\n"
    out += "\n"
    if args.write:
        with open(args.presets, "w") as fh:
            fh.write(out)
        print(f"\nWROTE {args.presets}")
    else:
        print("\n=== proposed presets.ini (dry-run) ===")
        print(out)


if __name__ == "__main__":
    main()
