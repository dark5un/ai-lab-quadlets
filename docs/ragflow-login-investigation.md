# RAGFlow console login — investigation plan (clean-session handoff, opened 2026-11-11)

Symptom (owner): at `https://ai.<tailnet>.ts.net:8444/login` login "does not
work"; earlier a `code:109 email and password do not match` hint in Chrome.

## Already established (verified this session — do not re-verify, trust + build)

- **Server accepts the card's kb-bot pair on the browser's exact path**:
  `POST https://ai.<tailnet>.ts.net:8444/api/v1/auth/login`
  {kb-bot@local.ai, .kbuser_pw_once value} -> HTTP 200 `"code":0`
  (tested via loopback :3114 AND via the TLS door, 2026-11-11).
- **admin@ragflow.io is rejected at /login BY DESIGN**: "super admin should
  not login to this page" (observed before any changes were made). Admin
  belongs at `:8444/admin`; the admin API login verified `code:0` there
  BEFORE the 2026-11-11 rotation.
- Admin password rotated 2026-11-11 as a trio: `config/ragflow/.admin_pw_once`
  + `ADMIN_DEFAULT_PASSWORD` (service.env, verified identical) + DB
  werkzeug-scrypt row (`scrypt:32768:8:1$b64salt$hex64`), verified by DB
  read-back only.
- Frontend does NOT md5-hash passwords (no `md5` in `/ragflow/web/dist` login
  bundle; it calls exactly `/api/v1/auth/login`).
- Containers/logs: `systemd-ragflow` = Go server v1.0.0-rc3 — api on :9380,
  **admin on separate :9381**, logs `/ragflow/logs/{api_server_9380,
  admin_server_9381,ingestor_server}.log` — but **successful requests are NOT
  logged** (warn-level only), so log absence proves nothing.
- User table healthy: both users status=1/is_active=1; no lockout columns
  there; kb-bot row untouched ever (only its hash from creation 2026-11-04).
- Owner's Chrome paste showed heavy **1Password extension noise** -> stale
  autofill is a live hypothesis.

## Hard rules for this investigation

1. NEVER log in as admin@ragflow.io (owner directive 2026-11-11). kb-bot is
   the bot's own account — testing with it is allowed.
2. Do not "repair" any credential to a file value without asking the owner
   (the 2026-11-11 incident: the mismatch may be his deliberate choice).
3. Any wire-capture of login payloads must be ephemeral, and password values
   must never land in repo/docs/journal output (log keys/lengths only).

## Step 1 — pin the exact symptom (do this FIRST; cheap)

Ask the owner (or watch his screen via his DevTools export):
- Which email is typed at /login? (admin@... there = expected refusal, done)
- Exact UI message string + code number.
- Browser DevTools Network: the `auth/login` request — status, full response
  body, and whether a captcha field is present in the payload.
The `109` vs "super admin..." vs a 429-ish message each point to a different
branch below.

## Step 2 — browser-path reproduction (no admin creds)

Use the browser tool (or `podman run --network systemd-ai` headless browser)
against `https://ai.<tailnet>.ts.net:8444/login` and submit
kb-bot + `ailab-access` row value:
- If the UI flow succeeds -> problem is browser-local for the owner:
  1Password autofill, keyboard-layout char mangling, or wrong email. Fix:
  delete the 1Password entry, re-save from ailab-access output.
- If the UI flow fails while curl succeeds -> the SPA sends something
  different: capture the POST body shape (Step 3).

## Step 3 — wire capture (only if Step 2 fails)

Temporary logging proxy (host, ~30 lines of Python, same pattern as
flyproxy used on 2026-11-11): listen 127.0.0.1:3115 -> systemd-ragflow:9380,
log method/path/body KEYS+lengths only. Repoint the door:
  tailscale serve --bg --https=8444 http://127.0.0.1:3115
repro, then RESTORE:
  tailscale serve --bg --https=8444 http://127.0.0.1:3114
and kill the proxy. Compare SPA payload vs the working curl JSON.

## Step 4 — failure-state / rate-limiter hunt (if 109 persists from the real
browser but curl with identical values passes)

- `strings /ragflow/bin/ragflow_server | grep -iE "attempt|lockout|too many|
  throttle|failed login"` (image path: /ragflow/bin/ragflow_server).
- Check config: /ragflow/conf/*.yaml for login-threshold settings; kvrocks/
  redis (`systemd-ragflow-kvrocks`) for counter keys: `podman exec
  systemd-ragflow-kvrocks redis-cli keys '*login*'` (password:
  config/ragflow/service.env REDIS_PASSWORD).
- If a per-IP counter exists and the door's rewrite collapses the owner's
  browser to one source, many 1Password-driven wrong attempts could have
  tripped a temporary block that curl (different path/interval) dodges.
  Clear = wait out TTL or delete the keys; then have the owner retry once.

## Step 5 — decision + record

Root cause -> fix -> update this doc with a "RESOLVED" section (claim->probe
-> observed) + skill notes (ai-lab-pipeline-group) if a new pitfall surfaced.

## Quick-reference

- Credentials card: `ailab-access` (ragflow rows 1-3).
- Password trio tooling: `scripts/ragflow-fix-admin-password.sh`
  (default=repair DB from file; `--rotate`=new trio; never logs in).
- Door: `tailscale serve status` -> :8444 -> 127.0.0.1:3114.
- DB access: root via `config/ragflow/mysql.env` MYSQL_ROOT_PASSWORD,
  container `systemd-ragflow-mysql`, db `rag_flow`, table `user`.
