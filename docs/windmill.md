# Windmill automation group (deployed reality, 2026-11-05)

Plan: `~/tmp/windmill-jupyter-plan1.md` (P0). Replaces n8n for the KB's W1-W4
agentic pipelines (owner directive 2026-11-05); n8n stays running until W1-W4
run green here, then is deleted (plan P1.4).

## Units (group `automation`, all dormant - no [Install])

| unit | image | port | state |
|---|---|---|---|
| windmill-postgres | docker.io/library/postgres:18 | none (systemd-windmill-postgres:5432) | volume wm-db-data |
| windmill-server | ghcr.io/windmill-labs/windmill:1.862.0 | 127.0.0.1:3117 -> 8000 | health /api/health/status |
| windmill-worker | same image, MODE=worker WORKER_GROUP=default | none | volume wm-worker-cache |

All state (incl. the job queue) lives in Postgres. Start order: postgres ->
server -> worker (`scripts/ai-lab start` group). Secrets: `config/windmill/
service.env` (DATABASE_URL with mirrored DB password + SUPERADMIN_SECRET) and
`config/windmill-postgres/service.env` via generate/rotate-secrets.

## First boot - verified headless flow (scripts/windmill-bootstrap.sh)

A fresh 1.862.0 CE install has **no seeded admin**: the docs'
`admin@windmill.dev`/`changeme` login returns 400 against an empty `usr`
table (there is no SETUP_TOKEN / WM_DEFAULT_* env either - the plan's
candidates, both dead ends). The working bootstrap is:

1. `SUPERADMIN_SECRET` (env) acts as bearer for the virtual superadmin
   `superadmin@windmill.dev`.
2. `POST /api/users/create` {email, name, password, **super_admin**} -
   creates the INSTANCE-level account only.
3. `POST /api/workspaces/create` {id, name} (both required).
4. `POST /api/w/{ws}/workspaces/add_user` {email, is_admin, operator} -
   membership is per-workspace (`usr` table is per-workspace!); without this
   step logins work but `workspaces/list` is empty and tokens 401.
5. `POST /api/auth/login` -> **plaintext** JWT;
   `POST /api/users/tokens/create` {label, expiration, scopes, workspace_id,
   read_only} -> plaintext token stored at config/windmill/agent-token (600).
   Workspace-scoped tokens CANNOT call instance-level routes (401 on
   /workspaces/list) - verify via /w/{ws}/users/whoami.

Admin password: config/windmill/admin-password.txt (generated once, 600).

## Worker sandbox decision

Official compose runs workers `privileged` for unshare-PID isolation and has a
SEPARATE `native` worker group. We run one unprivileged default worker with
nsjail left at its default OFF (the env is `DISABLE_NSJAIL`, default true -
`ENABLE_NSJAIL` does not exist). NATIVE_MODE on the default worker is a
verified trap: it REFUSES dependency jobs ("Worker is in native mode and
cannot execute dependency jobs"), python lock jobs then fail, scripts never
deploy and run endpoints 404 with "script not found at name ...". Keep the
default worker native-free; add a dedicated native worker only when trigger
volume needs it.

## Script source of truth: windmill/ + scripts/windmill-sync.sh

The repo folder `windmill/` mirrors the workspace via the wmill CLI
(installed via mise/npm: `windmill-cli@1.862.1`):

    scripts/windmill-sync.sh push|pull

Verified conventions (1.862.1): content file is `f/<dir>/<name>.py` (NOT
`<name>.script.py` - sync push generated a `hello.script.lock` next to
`hello.script.py` and then crashed refusing to pair them); metadata/lock land
as `<name>.script.yaml` / `<name>.script.lock` after pull. `--base-url` forces
`--token` in argv (WM_TOKEN env alone is ignored by sync). Scripts under f/
need the FOLDER created; `wmill folder add-missing` prints a hint - sync push
creates it.

## Webhook/trigger endpoints (verified live)

Script "webhooks" are the run endpoints themselves (no /jobs_u/webhook route
exists in 1.862):

    POST /api/w/{ws}/jobs/run/p/{path}              async -> job id
    POST /api/w/{ws}/jobs/run_wait_result/p/{path}  sync -> result
    POST /api/w/{ws}/jobs/run_wait_result/h/{hash}  version-pinned

Auth: `Authorization: Bearer <token>` (agent-token) or `?token=`. The KB
watcher's completion hook will move from N8N_WEBHOOK_URL to a Windmill
schedule/webhook in plan P1 (rename pending, watcher env still points at n8n).

## Tailnet door (planned, not yet created)

Precedent svc:sketchlab: Tailscale Service `svc:windmill` ->
`https://windmill.<tailnet>.ts.net` (:443, tagged node, console "Define
Service" first). Until then loopback-only: http://127.0.0.1:3117.

## Gotchas (inherited from the n8n lessons, checked against Windmill)

- No header-stripping quirk class found; plain bearer auth works end-to-end
  (verified against this live instance).
- Script paths must have 3+ segments (`proper_id` check) and the server wants
  the extension-aware canonical form for raw-file routes.
- Empty-string codebase + lock-job failure = invisible undeployed script: when
  a run 404s despite scripts/get working, check deployment_status/h/{hash}
  job logs first.
