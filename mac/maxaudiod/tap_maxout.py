"""Passive RMS tap of MAX Out's capture side (what plex receives uplink).

RUN FROM THE OWNER'S TERMINAL ONLY: python spawned by the agent shell has
no Microphone TCC grant and reads EXACT digital zeros from every capture
stream (pitfall in docs/mac-virtual-devices-plan.md).

Usage:  uv run python tap_maxout.py [seconds]     (default 30)
Adds a second reader to the device; mutes nothing. Prints a 1 s RMS
envelope; speak into the meeting while it runs.
"""
import sys
import time

import numpy as np
import sounddevice as sd

SR = 48000
DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 30


def main():
    idx = None
    for i, d in enumerate(sd.query_devices()):
        if "MAX Out" in d["name"] and d["max_input_channels"] > 0:
            idx = i
    if idx is None:
        sys.exit("MAX Out not found")
    print(f"tapping MAX Out (device {idx}) for {DUR}s -- SPEAK NOW", flush=True)
    buf = []

    def cb(indata, frames, t, st):
        buf.append(indata[:, :].copy())

    with sd.InputStream(samplerate=SR, device=idx, channels=2, blocksize=960, callback=cb):
        t0 = time.time()
        while time.time() - t0 < DUR:
            time.sleep(0.5)
    audio = np.concatenate(buf)
    rms = np.sqrt(np.mean(audio**2, axis=1))
    print(f"== 1 s RMS (dBFS), {DUR}s ==")
    for s in range(DUR):
        seg = rms[s * SR : (s + 1) * SR]
        if len(seg) == 0:
            break
        r = float(np.sqrt(np.mean(seg**2)))
        db = -120.0 if r <= 0 else 20 * np.log10(r)
        print(f"{s:3d}s {db:7.1f} dB  {'#' * max(0, int((db + 70) * 1.2))}", flush=True)
    print("peak:", round(float(np.max(np.abs(audio))), 4))


if __name__ == "__main__":
    main()
