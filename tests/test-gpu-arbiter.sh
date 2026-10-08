#!/usr/bin/env bash
# GPU rules: scripts/gpu-arbiter.py's planner against the real registry.
# Each case: running services, request -> expected ordered ops.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'EOF'
import importlib.util, json, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("arb", f"{root}/scripts/gpu-arbiter.py")
arb = importlib.util.module_from_spec(spec); spec.loader.exec_module(arb)
reg = json.load(open(f"{root}/services.json"))

def ops(running, verb, name):
    return [f"{o} {n}" for o, n in arb.plan(reg, set(running), verb, name)]

cases = [
    # strata switching
    ("off -> 5090", [], "start", "strata-5090", ["start strata-5090"]),
    ("5090 -> 4070ti", ["strata-5090"], "start", "strata-4070ti",
        ["stop strata-5090", "start strata-4070ti"]),
    ("strata off", ["strata-both"], "stop", "strata", ["stop strata-both"]),
    # R1: GPU service on strata's card moves strata
    ("llama on 5090 moves strata", ["strata-5090"], "start", "llama-cpp-5090",
        ["stop strata-5090", "start strata-4070ti", "start llama-cpp-5090"]),
    ("rizzo on 4070ti moves strata", ["strata-4070ti"], "start", "rizzo",
        ["stop strata-4070ti", "start strata-5090", "start rizzo"]),
    ("strata off stays off", [], "start", "llama-cpp-5090", ["start llama-cpp-5090"]),
    ("other card: no move", ["strata-5090"], "start", "rizzo", ["start rizzo"]),
    # R1 + R2: strata priority on the new card, ComfyUI follows
    ("move stops 4070ti services", ["strata-5090", "rizzo", "llama-cpp-4070ti"], "start", "llama-cpp-5090",
        ["stop strata-5090", "stop llama-cpp-4070ti", "stop rizzo", "start strata-4070ti", "start llama-cpp-5090"]),
    ("move swaps comfyui", ["strata-5090", "comfyui-4070ti"], "start", "llama-cpp-5090",
        ["stop strata-5090", "stop comfyui-4070ti", "start strata-4070ti", "start comfyui-5090", "start llama-cpp-5090"]),
    # R2 direct
    ("strata-4070ti stops rizzo, moves comfy", ["rizzo", "comfyui-4070ti", "llama-cpp-5090"], "start", "strata-4070ti",
        ["stop comfyui-4070ti", "stop rizzo", "start strata-4070ti", "start comfyui-5090"]),
    # R3
    ("both stops every GPU service", ["llama-cpp-5090", "llama-cpp-4070ti", "rizzo", "comfyui-4070ti", "sketchlab"],
        "start", "strata-both",
        ["stop comfyui-4070ti", "stop llama-cpp-4070ti", "stop llama-cpp-5090", "stop rizzo", "start strata-both"]),
    ("both drops for llama", ["strata-both"], "start", "llama-cpp-5090",
        ["stop strata-both", "start strata-4070ti", "start llama-cpp-5090"]),
    ("both drops for rizzo", ["strata-both"], "start", "rizzo",
        ["stop strata-both", "start strata-5090", "start rizzo"]),
    # R4 ComfyUI placement
    ("comfy default 4070ti", [], "start", "comfyui", ["start comfyui-4070ti"]),
    ("comfy opposite strata", ["strata-4070ti"], "start", "comfyui", ["start comfyui-5090"]),
    ("comfy with strata-both", ["strata-both"], "start", "comfyui",
        ["stop strata-both", "start strata-5090", "start comfyui-4070ti"]),
    ("toggle comfy group off", ["comfyui-5090"], "toggle", "comfyui", ["stop comfyui-5090"]),
    # non-GPU services pass straight through
    ("sketchlab", ["strata-both"], "start", "sketchlab", ["start sketchlab"]),
    ("already running", ["strata-5090"], "start", "strata-5090", []),
    # R5: an exclusive service (llama-cpp-both) takes both cards
    ("llama-both stops everything GPU", ["strata-5090", "rizzo", "comfyui-4070ti", "llama-cpp-5090", "sketchlab"],
        "start", "llama-cpp-both",
        ["stop strata-5090", "stop comfyui-4070ti", "stop llama-cpp-5090", "stop rizzo", "start llama-cpp-both"]),
    ("llama-both stops strata-both", ["strata-both"], "start", "llama-cpp-both",
        ["stop strata-both", "start llama-cpp-both"]),
    ("llama-both already running", ["llama-cpp-both"], "start", "llama-cpp-both", []),
    # R6: any other GPU start stops the exclusive service first
    ("strata stops llama-both", ["llama-cpp-both", "sketchlab"], "start", "strata-4070ti",
        ["stop llama-cpp-both", "start strata-4070ti"]),
    ("llama-5090 stops llama-both", ["llama-cpp-both"], "start", "llama-cpp-5090",
        ["stop llama-cpp-both", "start llama-cpp-5090"]),
    ("comfy stops llama-both", ["llama-cpp-both"], "start", "comfyui",
        ["stop llama-cpp-both", "start comfyui-4070ti"]),
    ("rizzo stops llama-both", ["llama-cpp-both"], "toggle", "rizzo",
        ["stop llama-cpp-both", "start rizzo"]),
    ("non-GPU leaves llama-both", ["llama-cpp-both"], "start", "sketchlab", ["start sketchlab"]),
    ("toggle llama-both off", ["llama-cpp-both"], "toggle", "llama-cpp-both", ["stop llama-cpp-both"]),
    # llama-cpp group (bar widget row): stop/toggle-off the whole group
    ("stop llama group", ["llama-cpp-5090", "llama-cpp-4070ti", "sketchlab"], "stop", "llama-cpp",
        ["stop llama-cpp-5090", "stop llama-cpp-4070ti"]),
    ("toggle llama group off", ["llama-cpp-both"], "toggle", "llama-cpp", ["stop llama-cpp-both"]),
    ("single llama chips coexist", ["llama-cpp-5090"], "start", "llama-cpp-4070ti", ["start llama-cpp-4070ti"]),
    # 5090 context variants: one strata at a time, they swap like any variant
    ("256k -> 1m", ["strata-5090"], "start", "strata-5090-1m",
        ["stop strata-5090", "start strata-5090-1m"]),
    ("1m moves for llama-5090", ["strata-5090-1m"], "start", "llama-cpp-5090",
        ["stop strata-5090-1m", "start strata-4070ti", "start llama-cpp-5090"]),
    ("524k swaps comfyui", ["strata-4070ti", "comfyui-5090"], "start", "strata-5090-524k",
        ["stop strata-4070ti", "stop comfyui-5090", "start strata-5090-524k", "start comfyui-4070ti"]),
    # C1: strata-coder owns the 4070 Ti, beside a 5090 strata variant (duo)
    ("coder beside 5090-1m", ["strata-5090-1m"], "start", "strata-coder", ["start strata-coder"]),
    ("coder moves strata-4070ti to 5090", ["strata-4070ti"], "start", "strata-coder",
        ["stop strata-4070ti", "start strata-5090", "start strata-coder"]),
    ("coder drops strata-both", ["strata-both"], "start", "strata-coder",
        ["stop strata-both", "start strata-5090", "start strata-coder"]),
    ("coder stops 4070ti services", ["rizzo", "llama-cpp-4070ti", "llama-cpp-5090"], "start", "strata-coder",
        ["stop llama-cpp-4070ti", "stop rizzo", "start strata-coder"]),
    ("coder moves comfy to free 5090", ["comfyui-4070ti"], "start", "strata-coder",
        ["stop comfyui-4070ti", "start comfyui-5090", "start strata-coder"]),
    ("coder stops comfy when 5090 is strata's", ["strata-5090", "comfyui-4070ti"], "start", "strata-coder",
        ["stop comfyui-4070ti", "start strata-coder"]),
    # C2: strata on the coder's card stops it
    ("strata-4070ti stops coder", ["strata-coder"], "start", "strata-4070ti",
        ["stop strata-coder", "start strata-4070ti"]),
    ("strata-both stops coder", ["strata-5090", "strata-coder"], "start", "strata-both",
        ["stop strata-5090", "stop strata-coder", "start strata-both"]),
    ("5090 variant keeps coder", ["strata-5090", "strata-coder"], "start", "strata-5090-1m",
        ["stop strata-5090", "start strata-5090-1m"]),
    # C3: other 4070 Ti services stop the coder (it cannot move)
    ("rizzo stops coder", ["strata-5090", "strata-coder"], "start", "rizzo",
        ["stop strata-coder", "start rizzo"]),
    ("llama-5090 in duo: strata moves, coder stops", ["strata-5090", "strata-coder"], "start", "llama-cpp-5090",
        ["stop strata-5090", "stop strata-coder", "start strata-4070ti", "start llama-cpp-5090"]),
    ("comfy in duo stops coder", ["strata-5090", "strata-coder"], "start", "comfyui",
        ["stop strata-coder", "start comfyui-4070ti"]),
    ("comfy beside coder alone goes 5090", ["strata-coder"], "start", "comfyui", ["start comfyui-5090"]),
    ("llama-both stops duo", ["strata-5090", "strata-coder"], "start", "llama-cpp-both",
        ["stop strata-5090", "stop strata-coder", "start llama-cpp-both"]),
    ("coder stops llama-both", ["llama-cpp-both"], "start", "strata-coder",
        ["stop llama-cpp-both", "start strata-coder"]),
    ("strata off keeps coder", ["strata-5090", "strata-coder"], "stop", "strata", ["stop strata-5090"]),
]
fail = 0
for title, running, verb, name, want in cases:
    got = ops(running, verb, name)
    if got != want:
        fail = 1
        print(f"  FAIL {title}:\n    want {want}\n    got  {got}")
try:
    arb.plan(reg, set(), "start", "strata"); fail = 1; print("  FAIL bare 'strata' start must ask for a variant")
except arb.ArbiterError:
    pass
try:
    arb.plan(reg, set(), "start", "llama-cpp"); fail = 1; print("  FAIL bare 'llama-cpp' start must ask for a variant")
except arb.ArbiterError:
    pass
if fail:
    sys.exit(1)
print(f"GPU arbiter: {len(cases)} cases passed.")
EOF
