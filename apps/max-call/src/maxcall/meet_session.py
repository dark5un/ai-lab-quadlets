"""Native (browserless) Meet leg — EXPERIMENTAL / UNVERIFIED against live Meet.

meets the meetbot-pattern idea: with a pairing token obtained from an
authenticated notetaker flow (POST alkaline ...:allocateWebRtcCalloutPairToken)
a client can open wss://alkaline.google.com/o/webrtc-inbound-call, receive ICE
config (GET /v1/config/iceServerConfig/meet) and run a plain RTCPeerConnection.
Google's exact wire framing on that socket is not public; this module
implements the SDP/ICE mechanics with aiortc + synthetic avatar tracks so the
moment a token + meeting link are available the flow can be exercised.
No credentials are ever stored or logged.
"""
from __future__ import annotations

import asyncio
import json
import ssl
import urllib.request
from dataclasses import dataclass, field

from aiortc import RTCPeerConnection, RTCSessionDescription

from maxcall.tracks import SineAudioTrack, TestPatternVideoTrack

ALKALINE = "https://alkaline.google.com"
INBOUND_WS = "wss://alkaline.google.com/o/webrtc-inbound-call"


@dataclass
class MeetSession:
    """One native-style call: WS signaling + RTCPeerConnection with avatar tracks."""
    pair_token: str
    meeting_code: str
    pc: RTCPeerConnection = field(default_factory=RTCPeerConnection)
    ice_servers: list = field(default_factory=list)
    log: list = field(default_factory=list)

    def _note(self, msg: str) -> None:
        self.log.append(msg)

    def fetch_ice_config(self) -> list[dict]:
        """GET iceServerConfig (requires the same auth context that minted the
        pair token; 4xx here just means no usable auth context present)."""
        req = urllib.request.Request(f"{ALKALINE}/v1/config/iceServerConfig/meet",
                                     headers={"X-Goog-Authuser": ""}, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read().decode())
        except Exception as e:  # noqa: BLE001
            self._note(f"iceServerConfig unavailable: {type(e).__name__} {e}")
            return []

    async def run(self, hold_s: float = 60.0) -> dict:
        # avatar tracks
        self.pc.addTrack(TestPatternVideoTrack())
        self.pc.addTrack(SineAudioTrack())
        self.pc.on("connectionstatechange",
                   lambda: self._note(f"connectionState={self.pc.connectionState}"))
        self.pc.on("iceconnectionstatechange",
                   lambda: self._note(f"iceConnectionState={self.pc.iceConnectionState}"))
        recv = {"video": 0, "audio": 0}

        @self.pc.on("track")
        def _on_track(track):
            async def drain():
                try:
                    while True:
                        await track.recv()
                        recv[track.kind] += 1
                except Exception:
                    pass
            asyncio.ensure_future(drain())

        offer = await self.pc.createOffer()
        await self.pc.setLocalDescription(offer)
        self._note("local offer created (VP8 + Opus, unified-plan)")
        # --- the undocumented part: pair-token handshake on the inbound-call WS.
        # We attempt a minimal JSON hello; a real integration must match Google's
        # framing observed via the Playwright interceptor. ---
        try:
            import websockets  # optional dep
            sslctx = ssl.create_default_context()
            async with websockets.connect(
                    f"{INBOUND_WS}?token=***", ssl=sslctx,
                    open_timeout=10) as ws:
                await ws.send(json.dumps({
                    "request": {"pairToken": self.pair_token,
                                "callRequest": {"dialMeetingCode": self.meeting_code}}}))
                self._note("pairing hello sent; awaiting answer")
                deadline = asyncio.get_event_loop().time() + hold_s
                while asyncio.get_event_loop().time() < deadline:
                    msg = await asyncio.wait_for(ws.recv(), timeout=5)
                    self._note(f"<- {str(msg)[:120]}")  # truncated, never full payloads
        except ImportError:
            self._note("websockets not installed — native leg not attempted")
        except Exception as e:  # noqa: BLE001
            self._note(f"native leg handshake failed: {type(e).__name__}: {str(e)[:200]}")
        await self.pc.close()
        return {"ice_servers": len(self.ice_servers), "recv_frames": recv,
                "log": self.log,
                "status": "unverified-without-token"}
