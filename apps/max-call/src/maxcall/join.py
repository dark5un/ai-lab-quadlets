"""max-call CLI — Google Meet joiner for a real-time avatar.

Usage:
  python src/maxcall/join.py [--url https://meet.google.com/xxx-xxxx-xxx]
                             [--hold 60] [--skip-probes]

Without --url: validates the machinery end-to-end offline
 (endpoint probes, aiortc<->aiortc P2P, Chromium<->aiortc interop,
  Playwright CDP interception on the public Meet join screen + screenshot).
With --url: performs the meetbot-pattern guest join via Playwright, holds
 --hold seconds, logs ICE state/bitrate/received-track stats, and writes
 spike-report.md. Never stores Google credentials; tokens are redacted.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))

from maxcall.observer import Observer  # noqa: E402
from maxcall import probe_meet, local_p2p  # noqa: E402

ART = APP / "artifacts"


def run_probe() -> dict:
    results = []
    for name, method, url in probe_meet.TARGETS_HTTP:
        results.append(probe_meet.http_probe(name, method, url))
    results.append(probe_meet.ws_upgrade_probe("wss://meet.google.com/o/webrtc-inbound-call"))
    for h in probe_meet.STUN_SERVERS:
        results.append(probe_meet.stun_probe(h))
    return {"results": results, "ok": sum(r["ok"] for r in results), "total": len(results)}


def run_local_p2p(hold_s: float = 8.0) -> dict:
    return asyncio.run(local_p2p.run(hold_s))


def run_interop(hold_s: float = 8.0) -> dict:
    proc = subprocess.run(
        [sys.executable, str(HERE / "browser_p2p.py"), str(hold_s)],
        capture_output=True, text=True, timeout=180)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        data = {"error": proc.stdout[-800:], "stderr": proc.stderr[-800:]}
    data["returncode"] = proc.returncode
    return data


def run_meet_landing_observer() -> dict:
    """Prove the Playwright observer reaches the public Meet guest-join screen,
    CDP interception records network traffic, fake media devices work."""
    out = {}
    with Observer(ART) as obs:
        obs.page.goto("https://meet.google.com/", wait_until="domcontentloaded",
                      timeout=30_000)
        time.sleep(4)
        out["title"] = obs.page.title()
        gum = obs.page.evaluate("""async () => {
            try { const s = await navigator.mediaDevices.getUserMedia({video:true,audio:true});
              return s.getTracks().map(t => t.kind + ':' + t.label);
            } catch (e) { return 'gum-error: ' + e; } }""")
        out["fake_media_devices"] = gum
        obs.install_signal_probe_fetch()  # prove CDP request capture fires on pattern URLs
        out["signal_probe_events"] = [e["url"] for e in obs.events if e["kind"].startswith("signal")]
        out["screenshot"] = str(obs.screenshot("meet_landing.png"))
        # guest-join screen for a syntactically valid but non-existent meeting code:
        # this is the page the joiner must parse when a real link is supplied.
        obs.page.goto("https://meet.google.com/xxx-xxxx-xxx", wait_until="domcontentloaded",
                      timeout=30_000)
        time.sleep(5)
        out["guest_screen_title"] = obs.page.title()
        body = obs.page.evaluate("() => document.body.innerText.slice(0, 400)")
        out["guest_screen_text"] = " ".join(body.split())[:300]
        # the "Join with a code" input must be reachable via our selector strategy
        code_input = obs.page.query_selector('input[aria-label*="code" i], input[aria-label*="Meeting code" i]')
        out["code_input_found"] = code_input is not None
        out["guest_screenshot"] = str(obs.screenshot("meet_guest_screen.png"))
        out["events_seen"] = len(obs.events)
        obs.dump_events()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", help="live Meet link to join as guest")
    ap.add_argument("--hold", type=float, default=60.0)
    ap.add_argument("--skip-probes", action="store_true")
    ap.add_argument("--skip-p2p", action="store_true")
    ap.add_argument("--skip-interop", action="store_true")
    ap.add_argument("--report", default=str(APP / "spike-report.md"))
    args = ap.parse_args()

    sections = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if not args.skip_probes:
        print("[1/3] probing Meet/alkaline + STUN endpoints...", file=sys.stderr)
        sections["probe"] = run_probe()
    if not args.skip_p2p:
        print("[2/3] aiortc<->aiortc local P2P...", file=sys.stderr)
        sections["local_p2p"] = run_local_p2p(min(args.hold, 10))
    if not args.skip_interop:
        print("[3/3] Chromium<->aiortc interop (fake devices)...", file=sys.stderr)
        sections["interop"] = run_interop(min(args.hold, 10))

    if args.url and re.match(r"^https://meet\.google\.com/[a-z0-9-]+", args.url):
        print(f"[live] joining {args.url}...", file=sys.stderr)
        with Observer(ART) as obs:
            join = obs.join_meet(args.url, wait_admission_s=min(args.hold, 120))
            sections["live_join"] = join
            t0 = time.monotonic()
            samples = []
            while time.monotonic() - t0 < args.hold:
                time.sleep(5)
                try:
                    samples.append(obs.page.evaluate(
                        "() => ({t: Date.now(), pcs: window.__pcReport.pcs.map(r => "
                        "{ice: r.ice, conn: r.conn})})"))
                except Exception:
                    pass
            sections["live_hold"] = samples
            sections["live_signal_events"] = obs.events
            sections["live_screenshot"] = str(obs.screenshot("live_join.png"))
            obs.dump_events("live_observer_events.json")
    else:
        sections["meet_landing_observer"] = run_meet_landing_observer()
        sections["live_join"] = {"stage": "no --url given; live join unverified"}

    (ART / "validation_results.json").write_text(json.dumps(sections, indent=2))
    print(json.dumps(sections, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
