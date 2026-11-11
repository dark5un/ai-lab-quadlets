#!/usr/bin/env python3
"""Fake A2F 'bridge': streams the ARKit CSV fixture as WS JSON frames
{t: unix_seconds, bs: {ARKitName: 0..1}} at 30 Hz, looping. Lets the
?feed=bridge path be e2e-tested today with no real Audio2Face backend.

Run: python tools/fake-bridge.py [--port 8990] [--csv tests/fixtures/bs-frames.csv]
"""
import argparse, asyncio, csv, json, os, time
from pathlib import Path

import websockets

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8990)
ap.add_argument("--csv", default=str(Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "bs-frames.csv"))
args = ap.parse_args()

with open(args.csv) as f:
    rd = csv.DictReader(f)
    frames = [{k: float(v) for k, v in row.items() if k != "t"} for row in rd]
print(f"loaded {len(frames)} frames from {args.csv}")

async def handler(ws):
    i = 0
    try:
        while True:
            msg = {"t": time.time(), "bs": frames[i % len(frames)]}
            await ws.send(json.dumps(msg))
            i += 1
            await asyncio.sleep(1 / 30)
    except websockets.exceptions.ConnectionClosed:
        pass

async def main():
    async with websockets.serve(handler, "127.0.0.1", args.port, max_size=2**20):
        print(f"fake bridge on ws://127.0.0.1:{args.port}")
        await asyncio.Future()

asyncio.run(main())
