#!/usr/bin/env python3
"""gpu-arbiter.py: decide which units to stop/start so the GPU rules hold.

Rules (docs: ~/Documents/plans/strata-gpu-variants-plan.md, README "GPU rules"):
  R1  Starting a GPU service on a card strata occupies moves strata to the
      other card (strata-both drops to the other card). Strata off stays off.
  R2  Starting a single-card strata variant stops every non-strata service on
      that card, except ComfyUI, which moves to the other card.
  R3  Starting strata-both stops every GPU service.
  R4  ComfyUI runs on the card strata is NOT on (strata-both drops to the
      5090 for it; strata off -> the 4070 Ti).
  R5  Starting an exclusive service (registry "exclusive": true, e.g.
      llama-cpp-both) stops every other GPU service, strata included: it
      holds both cards, so strata has nowhere to move.
  R6  Starting any other GPU service (strata included) while an exclusive
      service runs stops the exclusive service first.
Non-strata, non-exclusive services may share a card with each other.

services.json fields used: name, unit, gpu (5090 | 4070ti | both), group,
variant, exclusive. A group name (strata, comfyui) is accepted where a service is.

  gpu-arbiter.py [--registry F] [--dry-run] start|stop|toggle <name>

The planner (plan()) is pure; main() reads the live state from systemd and
runs the ops with `systemctl --user`, in order.
"""
import argparse
import json
import os
import subprocess
import sys

CARDS = ("5090", "4070ti")
OTHER = {"5090": "4070ti", "4070ti": "5090"}
COMFY_DEFAULT = "4070ti"   # ComfyUI's card while strata is off


class ArbiterError(Exception):
    pass


def cards(svc):
    g = svc.get("gpu")
    if not g:
        return set()
    return set(CARDS) if g == "both" else {g}


class Planner:
    def __init__(self, registry, running):
        self.svcs = {s["name"]: s for s in registry["services"]}
        self.state = set(running)          # names, simulated as ops are planned
        self.ops = []                      # [("stop"|"start", name)]

    # --- registry helpers -------------------------------------------------------
    def group(self, g):
        return [s for s in self.svcs.values() if s.get("group") == g]

    def member(self, g, variant):
        for s in self.group(g):
            if s.get("variant") == variant:
                return s["name"]
        raise ArbiterError(f"no {g} variant '{variant}' in the registry")

    def live(self, g):
        for s in self.group(g):
            if s["name"] in self.state:
                return s["name"]
        return None

    def strata_cards(self):
        n = self.live("strata")
        return cards(self.svcs[n]) if n else set()

    # --- primitive ops ----------------------------------------------------------
    def stop(self, name):
        if name in self.state:
            self.state.discard(name)
            self.ops.append(("stop", name))

    def start(self, name):
        if name not in self.state:
            self.state.add(name)
            self.ops.append(("start", name))

    # --- rules -------------------------------------------------------------------
    def place_strata(self, variant):
        """Start strata on `variant` (R2/R3); ComfyUI follows to the other card."""
        target = self.member("strata", variant)
        if target in self.state:
            return
        want = cards(self.svcs[target])
        for s in self.group("strata"):
            self.stop(s["name"])
        comfy_moves = False
        for name in sorted(self.state):
            s = self.svcs.get(name, {})
            if s.get("group") == "strata" or not (cards(s) & want):
                continue
            if s.get("group") == "comfyui" and len(want) == 1:
                comfy_moves = True
            self.stop(name)
        self.start(target)
        if comfy_moves:
            self.start(self.member("comfyui", OTHER[next(iter(want))]))

    def start_comfyui(self, variant=None):
        held = self.strata_cards()
        if variant is None:
            if held == set(CARDS):
                self.place_strata("5090")          # R4: strata-both drops to the 5090
                held = {"5090"}
            variant = OTHER[next(iter(held))] if held else COMFY_DEFAULT
        elif variant in held:
            self.place_strata(OTHER[variant])      # R1
        for s in self.group("comfyui"):
            if s["variant"] != variant:
                self.stop(s["name"])
        self.start(self.member("comfyui", variant))

    def start_exclusive(self, name):
        """R5: an exclusive service gets every card to itself."""
        if name in self.state:
            return
        for s in self.group("strata"):
            self.stop(s["name"])
        for other in sorted(self.state):
            if other != name and cards(self.svcs.get(other, {})):
                self.stop(other)
        self.start(name)

    def stop_exclusive(self, keep):
        """R6: a GPU start first stops any running exclusive service."""
        for other in sorted(self.state):
            s = self.svcs.get(other, {})
            if other != keep and s.get("exclusive"):
                self.stop(other)

    def start_service(self, name):
        s = self.svcs[name]
        if s.get("exclusive"):
            self.start_exclusive(name)
            return
        held = self.strata_cards()
        for card in sorted(cards(s) & held):
            # R1: strata leaves this card (both -> the other card; one -> swap).
            self.place_strata(OTHER[card])
            held = self.strata_cards()
        self.start(name)

    # --- verbs -------------------------------------------------------------------
    def groups(self):
        return {s["group"] for s in self.svcs.values() if s.get("group")}

    def do_start(self, name):
        if name == "strata":
            raise ArbiterError("pick a strata variant: ai-lab strata 5090|4070ti|both")
        if name in self.groups() and name != "comfyui":
            variants = "|".join(s["variant"] for s in self.group(name))
            raise ArbiterError(f"pick a {name} variant: {variants}")
        if name == "comfyui":
            if self.live("comfyui") is None:
                self.stop_exclusive(None)              # R6
            self.start_comfyui()
            return
        if name not in self.svcs:
            raise ArbiterError(f"unknown service '{name}'")
        s = self.svcs[name]
        if cards(s) and not s.get("exclusive"):
            self.stop_exclusive(name)                  # R6
        if s.get("group") == "strata":
            self.place_strata(s["variant"])
        elif s.get("group") == "comfyui":
            self.start_comfyui(s["variant"])
        else:
            self.start_service(name)

    def do_stop(self, name):
        if name in self.groups():
            for s in self.group(name):
                self.stop(s["name"])
            return
        if name not in self.svcs:
            raise ArbiterError(f"unknown service '{name}'")
        self.stop(name)

    def is_running(self, name):
        if name in self.groups():
            return self.live(name) is not None
        return name in self.state

    def do_toggle(self, name):
        if self.is_running(name):
            self.do_stop(name)
        else:
            self.do_start(name)


def plan(registry, running, verb, name):
    p = Planner(registry, running)
    {"start": p.do_start, "stop": p.do_stop, "toggle": p.do_toggle}[verb](name)
    return p.ops


def running_services(registry):
    """Names whose unit is active (or starting) right now."""
    units = {s["unit"]: s["name"] for s in registry["services"]}
    out = subprocess.run(["systemctl", "--user", "show", "-p", "Id,ActiveState", *units],
                         capture_output=True, text=True).stdout
    running, cur = set(), {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur.get("ActiveState") in ("active", "activating", "reloading"):
                running.add(units.get(cur.get("Id"), ""))
            cur = {}
            continue
        k, _, v = line.partition("=")
        cur[k] = v
    running.discard("")
    return running


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    ap = argparse.ArgumentParser(description="Plan and apply GPU-aware start/stop of ai-lab services.")
    ap.add_argument("--registry", default=os.environ.get(
        "AI_LAB_REGISTRY", os.path.join(here, "..", "services.json")))
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    ap.add_argument("verb", choices=("start", "stop", "toggle"))
    ap.add_argument("name")
    a = ap.parse_args()

    registry = json.load(open(a.registry))
    units = {s["name"]: s["unit"] for s in registry["services"]}
    try:
        ops = plan(registry, running_services(registry), a.verb, a.name)
    except ArbiterError as e:
        print(f"ai-lab: {e}", file=sys.stderr)
        return 1
    if not ops:
        print(f"  {a.name}: nothing to do")
        return 0
    for op, name in ops:
        if a.dry_run:
            print(f"  would {op}: {name}")
            continue
        if op == "start":
            subprocess.run(["systemctl", "--user", "reset-failed", units[name]],
                           capture_output=True)
        r = subprocess.run(["systemctl", "--user", op, units[name]])
        if r.returncode != 0:
            print(f"ai-lab: {op} {name} failed (exit {r.returncode}); stopped here", file=sys.stderr)
            return r.returncode
        print(f"  {op}: {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
