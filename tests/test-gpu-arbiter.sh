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
if fail:
    sys.exit(1)
print(f"GPU arbiter: {len(cases)} cases passed.")
EOF
