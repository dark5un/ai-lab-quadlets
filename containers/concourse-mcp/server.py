#!/usr/bin/env python3
"""concourse-mcp: thin MCP bridge over the Concourse ATC REST API.

agentic-pipeline plan (docs/agentic-pipeline-plan.md) sec. 2.4 + 7.
Streamable HTTP on :8080, path /mcp (+ /healthz for the registry probe).

Auth model (two static bearer tokens, never shared):
  MCP_TOKEN_HERMES   -> logs into ATC as CONCOURSE_USER   (team pipeline->main)
                        full toolset
  MCP_TOKEN_PIPELINE -> logs into ATC as CONCOURSE_LOWPRIV_USER (team agent)
                        read + trigger + check only (management denied)

ATC machine auth (verified against fly/commands/login.go @ master,
2026-11-10 — resolves Appendix B #1): password grant against
<atc>/sky/issuer/token with client_id=fly, client_secret=Zmx5,
scopes openid profile email federated:id groups. Token cached until 401.

REST routes verified against atc/routes.go @ master (same session):
  SaveConfig        PUT  /api/v1/teams/:t/pipelines/:p/config  {"config":yaml,"instance_vars":{}}
  GetConfig         GET  /api/v1/teams/:t/pipelines/:p/config
  expose/unpause/pause  PUT (no body)
  CreateJobBuild    POST /api/v1/teams/:t/pipelines/:p/jobs/:j/builds
  GetBuild          GET  /api/v1/builds/:id
  AbortBuild        PUT  /api/v1/builds/:id/abort
  BuildEvents       GET  /api/v1/builds/:id/events (SSE)
  ListResources     GET  .../resources ; CheckResource POST .../resources/:r/check
  PinResourceVersion PUT .../resources/:r/versions/:resource_config_version_id:int/pin
  UnpinResource      PUT .../resources/:r/unpin
  PauseJob/UnpauseJob PUT .../jobs/:j/pause|unpause
  ListWorkers       GET /api/v1/workers ; ListPipelines GET /api/v1/pipelines
"""
import json
import os
import sys
import time
from contextvars import ContextVar

import httpx
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.routing import Route

ATC_URL = os.environ["CONCOURSE_ATC_URL"].rstrip("/")
PORT = int(os.environ.get("MCP_PORT", "8080"))

_TOKENS = {
    "hermes": {
        "token": os.environ["MCP_TOKEN_HERMES"],
        "user": os.environ["CONCOURSE_USER"],
        "password": os.environ["CONCOURSE_PASSWORD"],
        "team": "main",
        "privileged": True,
    },
    "pipeline": {
        "token": os.environ["MCP_TOKEN_PIPELINE"],
        "user": os.environ["CONCOURSE_LOWPRIV_USER"],
        "password": os.environ["CONCOURSE_LOWPRIV_PASSWORD"],
        "team": "agent",
        "privileged": False,
    },
}

# principal for the in-flight request (set by the auth middleware)
PRINCIPAL: ContextVar[dict | None] = ContextVar("principal", default=None)

# cached ATC access tokens per Concourse user
_atc_tokens: dict[str, str] = {}


def _atc_token(cfg: dict) -> str:
    cached = _atc_tokens.get(cfg["user"])
    if cached:
        return cached
    r = httpx.post(
        f"{ATC_URL}/sky/issuer/token",
        data={
            "grant_type": "password",
            "client_id": "fly",
            "client_secret": "Zmx5",
            "username": cfg["user"],
            "password": cfg["password"],
            "scope": "openid profile email federated:id groups",
        },
        timeout=15,
    )
    r.raise_for_status()
    tok = r.json()["access_token"]
    _atc_tokens[cfg["user"]] = tok
    return tok


def _api(method: str, path: str, *, body=None, params=None):
    p = PRINCIPAL.get()
    if p is None:  # pragma: no cover - middleware guarantees a principal
        raise RuntimeError("no authenticated principal")
    cfg = _TOKENS[p["kind"]]

    def call(tok: str):
        return httpx.request(
            method,
            f"{ATC_URL}{path}",
            headers={"Authorization": f"Bearer {tok}"},
            json=body,
            params=params,
            timeout=60,
        )

    r = call(_atc_token(cfg))
    if r.status_code == 401:
        _atc_tokens.pop(cfg["user"], None)
        r = call(_atc_token(cfg))
    if r.status_code == 403:
        raise RuntimeError(
            f"ATC rejected {method} {path} (403). The MCP bearer token maps to "
            f"exactly one Concourse team; cross-team calls need the "
            f"Hermes-grade token."
        )
    if r.status_code >= 400:
        raise RuntimeError(f"ATC {method} {path} -> {r.status_code}: {r.text[:400]}")
    if r.status_code == 204 or not r.content:
        return None
    return r.json()


def _team() -> str:
    p = PRINCIPAL.get()
    return _TOKENS[p["kind"]]["team"]


def _require_privileged(action: str) -> None:
    p = PRINCIPAL.get()
    if not _TOKENS[p["kind"]]["privileged"]:
        raise RuntimeError(
            f"'{action}' is not permitted for the in-pipeline token "
            "(read/trigger/check only; use the Hermes-grade token)"
        )


mcp = MCPServer("concourse")


@mcp.tool()
def list_pipelines() -> list:
    """List every pipeline the caller's team can see (name, team, paused)."""
    if _TOKENS[PRINCIPAL.get()["kind"]]["privileged"]:
        rows = _api("GET", "/api/v1/pipelines")
    else:
        rows = _api("GET", f"/api/v1/teams/{_team()}/pipelines")
    return [
        {"name": x.get("name"), "team": x.get("team_name") or _team(),
         "paused": x.get("paused", False)}
        for x in rows
    ]


@mcp.tool()
def get_pipeline_config(pipeline: str) -> str:
    """Return the YAML config currently saved for a pipeline."""
    d = _api("GET", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/config")
    return d.get("configuration", "")


@mcp.tool()
def set_pipeline(pipeline: str, yaml_config: str) -> dict:
    """set_pipeline equivalent: save YAML config, expose + unpause. Hermes-grade token only."""
    _require_privileged("set_pipeline")
    t = _team()
    _api("PUT", f"/api/v1/teams/{t}/pipelines/{pipeline}/config",
         body={"config": yaml_config, "instance_vars": {}})
    _api("PUT", f"/api/v1/teams/{t}/pipelines/{pipeline}/expose")
    _api("PUT", f"/api/v1/teams/{t}/pipelines/{pipeline}/unpause")
    return {"pipeline": pipeline, "team": t, "saved": True}


@mcp.tool()
def trigger_job(pipeline: str, job: str) -> dict:
    """Queue a new build of a job; returns the build id/name."""
    b = _api("POST", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/jobs/{job}/builds",
             body={})
    return {"build_id": b.get("id"), "name": b.get("name"), "status": b.get("status")}


@mcp.tool()
def build_status(build_id: int) -> dict:
    """Status of one build (status/job/pipeline/timestamps)."""
    b = _api("GET", f"/api/v1/builds/{build_id}")
    return {"id": b.get("id"), "status": b.get("status"), "job": b.get("job_name"),
            "pipeline": (b.get("pipeline") or {}).get("name"),
            "create_time": b.get("create_time"), "start_time": b.get("start_time"),
            "end_time": b.get("end_time")}


@mcp.tool()
def tail_build_events(build_id: int, max_events: int = 300, timeout_s: int = 60) -> list:
    """Follow a build's SSE event stream; returns compacted [event, stdout] rows.
    Stops at stream end (build finished), max_events, or timeout_s."""
    tok = _atc_token(_TOKENS[PRINCIPAL.get()["kind"]])
    out: list = []
    deadline = time.monotonic() + timeout_s
    with httpx.stream(
        "GET", f"{ATC_URL}/api/v1/builds/{build_id}/events",
        headers={"Authorization": f"Bearer {tok}"}, timeout=timeout_s + 10,
    ) as s:
        s.raise_for_status()
        for line in s.iter_lines():
            if not line.startswith("data:"):
                continue
            try:
                ev = json.loads(line[5:].strip())
            except json.JSONDecodeError:
                continue
            name = ev.get("event", "")
            data = ev.get("data") or {}
            text = data.get("stdout") or data.get("message") or ""
            out.append({"event": name, "output": text[:2000]})
            if name == "finish" or len(out) >= max_events or time.monotonic() > deadline:
                break
    return out


@mcp.tool()
def abort_build(build_id: int) -> dict:
    """Abort a running build. Hermes-grade token only."""
    _require_privileged("abort_build")
    r = _api("PUT", f"/api/v1/builds/{build_id}/abort")
    return {"build_id": build_id, "aborted": bool((r or {}).get("aborted", True))}


@mcp.tool()
def list_resources(pipeline: str) -> list:
    """Resources of a pipeline: name, last check, pinned version, failing flag."""
    rows = _api("GET", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/resources")
    return [
        {"name": x.get("name"), "type": x.get("type"),
         "pinned_version": x.get("pinned_version"),
         "last_check_status": x.get("check_result", {}).get("status")
         if x.get("check_result") else None}
        for x in rows
    ]


@mcp.tool()
def check_resource(pipeline: str, resource: str) -> dict:
    """Trigger an immediate resource check (the CheckResource route; the
    Forgejo-webhook path uses the same endpoint)."""
    _api("POST", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/resources/{resource}/check")
    return {"pipeline": pipeline, "resource": resource, "check_requested": True}


@mcp.tool()
def pin_resource(pipeline: str, resource: str, version: dict) -> dict:
    """Pin a resource to a version (version = the JSON version map, e.g.
    {"ref":"main"} for git or {"path":"build/latest.tar.gz"} for s3).
    Hermes-grade token only."""
    _require_privileged("pin_resource")
    t = _team()
    base = f"/api/v1/teams/{t}/pipelines/{pipeline}/resources/{resource}"
    rows = _api("GET", f"{base}/versions")
    target = None
    for row in rows:
        if row.get("version") == version:
            target = row.get("id")  # resource_config_version_id (int)
            break
    if target is None:
        raise RuntimeError(
            f"version {version!r} not among checked versions of {pipeline}/{resource}; "
            f"known: {[r.get('version') for r in rows][:20]}"
        )
    _api("PUT", f"{base}/versions/{target}/pin")
    return {"pipeline": pipeline, "resource": resource, "pinned": version}


@mcp.tool()
def unpin_resource(pipeline: str, resource: str) -> dict:
    """Remove the pin from a resource. Hermes-grade token only."""
    _require_privileged("unpin_resource")
    _api("PUT", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/resources/{resource}/unpin")
    return {"pipeline": pipeline, "resource": resource, "unpinned": True}


@mcp.tool()
def pause_unpause_job(pipeline: str, job: str, pause: bool) -> dict:
    """Pause or unpause one job. Hermes-grade token only."""
    _require_privileged("pause_unpause_job")
    verb = "pause" if pause else "unpause"
    _api("PUT", f"/api/v1/teams/{_team()}/pipelines/{pipeline}/jobs/{job}/{verb}")
    return {"pipeline": pipeline, "job": job, "paused": pause}


@mcp.tool()
def list_workers() -> list:
    """Concourse workers with state."""
    rows = _api("GET", "/api/v1/workers")
    return [
        {"name": x.get("name"), "state": x.get("state"),
         "team": x.get("team_name"), "addr": x.get("addr")}
        for x in rows
    ]


# ---- transport + bearer auth middleware -------------------------------

class BearerAuth:
    """Pure-ASGI middleware: maps the bearer token to a principal and 401s
    everything else. Passes through lifespan."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if scope.get("path", "") == "/healthz":  # registry liveness (no auth)
            await self.app(scope, receive, send)
            return
        headers = {k.decode().lower(): v.decode()
                   for k, v in scope.get("headers", [])}
        auth = headers.get("authorization", "")
        kind = None
        for name, cfg in _TOKENS.items():
            if auth == f"Bearer {cfg['token']}":
                kind = name
                break
        if kind is None:
            body = b'{"error":"unauthorized"}'
            await send({"type": "http.response.start", "status": 401,
                        "headers": [(b"content-type", b"application/json")]})
            await send({"type": "http.response.body", "body": body})
            return
        tok = PRINCIPAL.set({"kind": kind})
        try:
            await self.app(scope, receive, send)
        finally:
            PRINCIPAL.reset(tok)


async def _healthz(request):
    from starlette.responses import JSONResponse
    return JSONResponse({"status": "ok", "atc": ATC_URL})


def main() -> None:
    app = mcp.streamable_http_app(
        stateless_http=True,
        host="0.0.0.0",
        # SDK 2.x leaves Host-validation OFF unless configured: enable it with
        # an exact allowlist for the two verified consumers (Hermes via the
        # loopback publish, Concourse tasks via the container-network name).
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*",
                           "systemd-concourse-mcp:*"],
        ),
    )
    app.routes.append(Route("/healthz", _healthz, methods=["GET"]))  # registry probe (no auth)
    app.add_middleware(BearerAuth)
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")


if __name__ == "__main__":
    missing = [k for k, cfg in _TOKENS.items() if not cfg["token"] or not cfg["password"]]
    if missing:
        sys.exit(f"mcp.env incomplete for: {', '.join(missing)} "
                 "(tokens/credentials must be generated by generate-secrets.sh)")
    main()
