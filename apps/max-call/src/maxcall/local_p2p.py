"""Self-hosted WebRTC validation: two aiortc RTCPeerConnections in-process
(loopback ICE + DTLS + SRTP), one side sends the synthetic avatar tracks
(640x480 VP8 test pattern + 440 Hz Opus tone), the other receives and we
measure fps / bitrate / ICE state. Proves the full track plumbing that the
Meet joiner depends on, with zero external dependencies.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from aiortc import RTCPeerConnection, RTCSessionDescription  # noqa: E402
from maxcall.tracks import SineAudioTrack, TestPatternVideoTrack  # noqa: E402

HOLD_S = 10.0


async def run(hold_s: float = HOLD_S) -> dict:
    a, b = RTCPeerConnection(), RTCPeerConnection()
    a.addTrack(TestPatternVideoTrack())
    a.addTrack(SineAudioTrack())

    counters = {"video_frames": 0, "audio_frames": 0, "video_bytes": 0,
                "audio_bytes": 0, "first_v": None, "last_v": None,
                "first_a": None, "last_a": None, "sizes": []}

    async def consume(track, kind):
        n = 0
        try:
            while True:
                frame = await track.recv()
                now = time.monotonic()
                if counters[f"first_{kind[0]}"] is None:
                    counters[f"first_{kind[0]}"] = now
                counters[f"last_{kind[0]}"] = now
                counters[f"{kind}_frames"] += 1
                if kind == "video":
                    counters["video_bytes"] += frame.width * frame.height * 3
                    if n < 3:
                        counters["sizes"].append((frame.width, frame.height, frame.format.name))
                    n += 1
                else:
                    counters["audio_bytes"] += sum(p.buffer_size for p in frame.planes)
        except Exception as e:  # surface the real error instead of silent death
            print(f"consume-{kind} stopped: {type(e).__name__}: {e}", file=sys.stderr)

    @b.on("track")
    def on_track(track):
        asyncio.ensure_future(consume(track, "video" if track.kind == "video" else "audio"))

    # non-trickle: aiortc's setLocalDescription completes ICE gathering, so the
    # localDescription SDP already carries all candidates (ordering-safe)
    await a.setLocalDescription(await a.createOffer())
    await b.setRemoteDescription(a.localDescription)
    await b.setLocalDescription(await b.createAnswer())
    await a.setRemoteDescription(b.localDescription)

    t0 = time.monotonic()
    while time.monotonic() - t0 < hold_s:
        await asyncio.sleep(1)

    result = {
        "ice_a": a.iceConnectionState, "ice_b": b.iceConnectionState,
        "dtls_a": a.connectionState, "dtls_b": b.connectionState,
        "video_recv_frames": counters["video_frames"],
        "video_fps": round(counters["video_frames"] / hold_s, 2),
        "audio_recv_frames": counters["audio_frames"],
        "audio_fps": round(counters["audio_frames"] / hold_s, 2),
        "video_encrypted_bytes_s": round(counters["video_bytes"] * 8 / hold_s),
        "audio_bytes_s": round(counters["audio_bytes"] * 8 / hold_s),
        "frame_shapes": counters["sizes"],
        "hold_s": hold_s,
    }
    await a.close()
    await b.close()
    return result


def main() -> int:
    hold = float(sys.argv[1]) if len(sys.argv) > 1 else HOLD_S
    res = asyncio.run(run(hold))
    print(json.dumps(res, indent=2))
    ok = (res["dtls_a"] == "connected" and res["video_recv_frames"] > 0
          and res["audio_recv_frames"] > 0 and res["video_fps"] > 5)
    print("PASS" if ok else "FAIL", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
