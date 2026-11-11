"""Probe Meet / alkaline WebRTC signaling + ICE endpoint reachability from this
host (no credentials sent, GET/POST with empty bodies only).

Reachability = DNS + TCP + TLS + an HTTP/WS response (even 4xx/401 proves the
endpoint exists and answers; only network-level failures count as unreachable).
"""
from __future__ import annotations

import json
import socket
import ssl
import struct
import sys
import time

import urllib.request
import urllib.error

TARGETS_HTTP = [
    ("meet landing", "GET", "https://meet.google.com/"),
    ("alkaline root (legacy Duo gw)", "GET", "https://alkaline.google.com/"),
    ("callout pair token (signaling auth)", "POST",
     "https://alkaline.google.com/v1/sessions:allocateWebRtcCalloutPairToken"),
    ("ice server config", "GET",
     "https://alkaline.google.com/v1/config/iceServerConfig/meet"),
    ("webrtc-inbound-call on meet host", "GET",
     "https://meet.google.com/o/webrtc-inbound-call"),
    ("webrtc-inbound-call (ws upgrade via https)", "GET",
     "https://alkaline.google.com/o/webrtc-inbound-call"),
]

STUN_SERVERS = [
    "stun.l.google.com", "alt1.stun.l.google.com", "alt2.stun.l.google.com",
    "alt3.stun.l.google.com", "alt4.stun.l.google.com", "alt5.stun.l.google.com",
]
STUN_PORT = 19302


def http_probe(name: str, method: str, url: str) -> dict:
    t0 = time.monotonic()
    out = {"check": name, "url": url, "method": method}
    try:
        req = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            out["status"] = r.status
    except urllib.error.HTTPError as e:
        out["status"] = e.code  # endpoint answered -> reachable
    except Exception as e:  # noqa: BLE001
        out["error"] = f"{type(e).__name__}: {e}"
    out["ok"] = "status" in out
    out["ms"] = round((time.monotonic() - t0) * 1000)
    return out


def ws_upgrade_probe(url: str) -> dict:
    """Raw TLS+WS Upgrade handshake for the inbound-call signaling path."""
    from urllib.parse import urlsplit
    parts = urlsplit(url)
    host, path = parts.hostname, parts.path or "/"
    out = {"check": "webrtc-inbound-call WS upgrade", "url": url}
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, parts.port or 443), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                key = "dGhlIG1vdXNlLw=="
                req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                       "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
                tls.sendall(req.encode())
                resp = tls.recv(4096).decode(errors="replace")
        out["response_head"] = resp.split("\r\n\r\n")[0][:300]
        out["status_line"] = resp.split("\r\n", 1)[0]
        out["ok"] = True
    except Exception as e:  # noqa: BLE001
        out["error"] = f"{type(e).__name__}: {e}"
        out["ok"] = False
    return out


def stun_probe(host: str, port: int = STUN_PORT) -> dict:
    """RFC 5389 STUN Binding request, 20 s budget -> proves ICE server live."""
    out = {"check": f"stun:{host}:{port}", "ok": False}
    try:
        addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
        # Binding request: type=0x0001 len=0 magic=0x2112A442 + 12-byte txn id
        txn = b"\x11\x22\x33\x44" + b"\x00" * 8
        msg = struct.pack(">HHI", 0x0001, 0, 0x2112A442) + txn
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(15)
            s.sendto(msg, addr)
            data, _ = s.recvfrom(1024)
        mtype = struct.unpack(">H", data[:2])[0]
        out["binding_response_type"] = hex(mtype)  # 0x0101 = success
        out["ok"] = mtype == 0x0101
    except Exception as e:  # noqa: BLE001
        out["error"] = f"{type(e).__name__}: {e}"
    return out


def main() -> int:
    results = []
    for name, method, url in TARGETS_HTTP:
        results.append(http_probe(name, method, url))
    results.append(ws_upgrade_probe("wss://meet.google.com/o/webrtc-inbound-call"))
    for h in STUN_SERVERS:
        results.append(stun_probe(h))
    print(json.dumps(results, indent=2))
    ok = sum(1 for r in results if r["ok"])
    print(f"\n{ok}/{len(results)} probes reachable", file=sys.stderr)
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
