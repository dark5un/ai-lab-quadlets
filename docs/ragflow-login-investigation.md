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

## Findings — session 2 (2026-11-11, clean handoff)

Step 1 answers (owner, live): failure happens for BOTH admin and kb-bot at
/login; exact UI string = `code:109 email and password do not match`; NO
captcha; password typed manually (1Password autofill hypothesis weakened,
not eliminated). DevTools payload capture promised — pending.

Step 2/3 shortcut (no live browser on this box — chromium libs missing, sudo
blocked): read the SPA's own shipped bundle from :3114 instead of wire-capture.
- `chunk/js/llm-util-*.js`: `login: POST /api/v1/auth/login`, body = raw form
  values. `chunk/js/login-*.js` form fields: **email, password, remember** —
  no captcha, no hashing, no extra fields. `/login-next` is a route alias to
  the same chunk. -> Browser path is packet-identical to the working curl.

kb-bot — verified consistent (claim -> probe -> observed):
- claim: file value is the live password. probe: recompute werkzeug scrypt
  (`scrypt:32768:8:1$base64salt$hex64`, n=32768,r=8,p=1,dklen=64, salt used as
  its base64 STRING bytes) over `.kbuser_pw_once` value vs DB row.
  observed: **MATCH**. (Also proves the script's hashing scheme == server's.)
- row `update_time` 2026-11-11 10:20:07Z = last_login bump from our successful
  curl tests; password column untouched (hash still matches creation-era file).
=> 109 from the owner's browser means he is TYPING A DIFFERENT VALUE. Prime
suspect: the card (`ailab-access`) shows TWO kb-bot rows — row 1 = 32-hex
LOGIN password, row 2 = long `ragflow-…`-prefixed **API token (NOT a login
password)**. Typing row 2 yields exactly code:109.

admin — TRIO DRIFT CONFIRMED, and it predates/excludes the known rotation:
- `.admin_pw_once` (mtime 2026-11-11 10:16:27Z) + `ADMIN_DEFAULT_PASSWORD`
  (same mtime, byte-identical) do **NOT** hash to the current DB row.
- DB row `update_time` = **10:13:58Z** — 2.5 min BEFORE the file trio was
  written, so the rotation's own DB write is not the row we now see (or the
  trio was later edited); server re-seed at restart also ruled out (service.env
  value == file value, so a re-seed WOULD match).
- => live admin password is currently UNKNOWN to us; /login refusal for admin
  is by design anyway ("super admin..." — UI may surface it as 109 too).
  Admin login belongs at :8444/admin ONLY.
- HARD RULE 2 APPLIES: do NOT run `ragflow-fix-admin-password.sh` (repair or
  rotate) before asking the owner if the mismatch is his deliberate custom
  password (2026-11-11 incident history + the script's own CAUTION note).

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

## RESOLVED (2026-11-11, session 2)

Root causes, claim -> probe -> observed:
1. **kb-bot /login 109**: claim "owner types a value that isn't the live
   password". Probe: scrypt recompute of `.kbuser_pw_once` vs DB row + SPA
   bundle payload diff. Observed: hash MATCHES; SPA payload == curl payload.
   The `ailab-access` card has two kb-bot rows; row 2 (`ragflow-…`-prefixed)
   is the API PAT, not a login password. Fix: type row 1 (or `ailab-access`
   ragflow row 1). Owner's browser path was never broken.
2. **admin trio drift**: root cause = BUG in `scripts/ragflow-fix-admin-
   password.sh` — `podman exec` WITHOUT `-i` feeds the container `/dev/null`,
   so the piped `mysql < /dev/stdin` ran ZERO statements (exit 0), while the
   format-only read-back "verified" the STALE old row. Every DB write the
   script ever performed was silently a no-op; only the file/env halves of
   the "trio" were ever written.
   Fix (owner-authorized "repair"): script now uses `podman exec -i`, sets
   `update_time`, and proves writes by EXACT match of the freshly generated
   random-salt hash. Repair re-run -> independent scrypt recompute of the DB
   row against both `.admin_pw_once` and `ADMIN_DEFAULT_PASSWORD`: both True.
   Trio fully converged; live admin password == the recorded file value.
   NOTE: the previous live admin hash (row from 10:13:58Z) is now overwritten
   — per the standing lesson, flagged so the owner knows if that value was
   ever his own custom choice.
3. admin@ragflow.io at `/login` = by design ("super admin ...") — admin
   console lives at `:8444/admin` only. This remains true and is not a bug.

Residual hygiene: make scripts/ragflow-fix-admin-password.sh executable
(chmod +x) next touch; browser tooling on this box lacks chromium shared
libs (sudo-gated) — bundle-reading + offline hash probes cover this class
of investigation without a live browser.

## Quick-reference

- Credentials card: `ailab-access` (ragflow rows 1-3).
- Password trio tooling: `scripts/ragflow-fix-admin-password.sh`
  (default=repair DB from file; `--rotate`=new trio; never logs in).
- Door: `tailscale serve status` -> :8444 -> 127.0.0.1:3114.
- DB access: root via `config/ragflow/mysql.env` MYSQL_ROOT_PASSWORD,
  container `systemd-ragflow-mysql`, db `rag_flow`, table `user`.
