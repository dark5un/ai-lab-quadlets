#!/usr/bin/env python3
"""Enable LightRAG API-key auth for tailnet exposure: generate a key into
config/lightrag/service.env and mirror it into config/kb-watcher/service.env
(needs it for watcher/analysis calls). Idempotent."""
import pathlib, secrets

def upsert(path: pathlib.Path, key: str, val: str | None = None) -> str:
    t = path.read_text()
    line = next((l for l in t.splitlines() if l.startswith(key + "=") and l.split("=", 1)[1]), None)
    if line:
        return line.split("=", 1)[1]
    v = val or secrets.token_hex(24)
    path.write_text(t.rstrip("\n") + f"\n{key}={v}\n")
    path.chmod(0o600)
    return v

conf = pathlib.Path.home() / ".config/containers/config"
k = upsert(conf / "lightrag/service.env", "LIGHTRAG_API_KEY")
upsert(conf / "kb-watcher/service.env", "LIGHTRAG_API_KEY", k)
print("lightrag auth key generated + mirrored (value not printed)")
