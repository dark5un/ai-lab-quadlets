# Cleanup plan — ai-lab-quadlets

Status: IN PROGRESS — phases 0-2 executed 2026-10-05 (commits on main).
The ai-lab.just recipes and docs/ujust-integration.md were removed by operator
request; install.sh, uninstall.sh and scripts/ai-lab are the only entry points.
Written 2026-10-05 after the
port renumbering (31xx web / 1143x model APIs), the services.json registry,
the scripts/ai-lab CLI, and the Ryoku `ailab` bar plugin landed. A fresh
agent can pick this up top to bottom; each phase is independently verifiable.

Repo: ~/workspace/github.com/dark5un/ai-lab-quadlets
Live stack truth: `./scripts/ai-lab status` (reads services.json).

## Ground rules (do not break)

- strata stays frozen: port 11437, loopback bind, do not touch its quadlet
  or config (model-serving dependency of the operator's agent).
- llama-cpp-research stays in the repo but NOT boot-enabled (no [Install]
  stanza); started manually only.
- Caddy config files (config/caddy/*, quadlets/caddy.container) are kept for
  reference but must never be deployed or started.
- deepseek-harness must stay loopback-only (Network=host, dsh binds
  127.0.0.1 itself). Never re-add the TCP bridge or client patches.
- The Ryoku plugin contract: never edit anything under
  ~/.local/share/ryoku/plugins/ or ~/.config/quickshell/; author in the
  repo copy, install with `ryoku plugin add`.

## Phase 0 — commit the working tree

Everything below is currently UNCOMMITTED (modified quadlets, install.sh,
just, README, docs, new services.json, scripts/ai-lab, docs/port-plan.md,
deleted patch-client-loopback.mjs, new strata files, tests/).
1. `git diff` review, split into logical commits:
   a. port renumbering + services.json registry + port-plan doc
   b. network-online.target removal + podman-user-wait mask note
   c. llama-cpp-research [Install] removal (kept stopped by default)
   d. deepseek-harness de-patching (bridge + patch script removed,
      Network=host)
   e. scripts/ai-lab CLI
   f. open-webui backend host/key fix (systemd-llama-cpp-main + real key)
2. Do NOT commit secrets: config/*/service.env files contain real keys
   (llama API key, WEBUI_SECRET_KEY). Verify .gitignore covers them;
   only *.example files may be tracked.

## Phase 1 — stale references audit

Grep for and fix every remaining reference to retired names/ports:
- `systemd-llama-cpp[^-]` (old container name; correct is
  systemd-llama-cpp-main). Known hits: quadlets/hermes.container
  `After=/Wants= systemd-llama-cpp.service`, config/hermes-service/
  service.env(.example) OPENAI_BASE_URL comment, README hermes section
  ("connects to systemd-llama-cpp").
- `ai.network` as a podman network name in README (~line 206): the quadlet
  file ai.network creates the network `systemd-ai`. The manual recovery
  snippet `podman network create ai.network` is wrong — it creates an
  orphan. Fix the snippet to `systemd-ai` or drop it (quadlet manages it).
- Old ports (3000, 3003, 3004, 3006, 3080, 3081, 8188 as HOST port) in
  docs/, config examples, justfile. Caddy files keep 3001-3005 by design.
- `DSH_INTERNAL_PORT`, `DSH_TRUSTED_HOSTS`, `DSH_ALLOW_REMOTE_CONFIGURATION`
  anywhere (all removed with the de-patch).
- `patch-client-loopback` mentions (README already cleaned; check docs/).
- N/A: the justfile was removed; scripts/ai-lab + uninstall.sh are the
  registry-driven entry points.

## Phase 2 — registry-driven install (kill duplicated truth)

install.sh, ai-lab.just, detect-gpus.sh and the docs still hardcode ports
that services.json already declares. Make services.json the only writer:
- install.sh: read host_port/bind/image per service from services.json
  (python3 one-liner, same pattern as scripts/ai-lab) for the summary
  block, firewall-cmd line, and the deploy loop's skip-list.
- ai-lab.just: `status`, `stop`, `start` targets iterate services.json.
- DONE: install.sh summary and ai-lab.just loops read services.json
  (ai-lab.just itself was later deleted; see status note above).
- DONE: tests/test-registry-consistency.sh — for every service in
  services.json, assert the deployed/repo quadlet's PublishPort matches
  host_port+bind+container_port, and the image matches. This test is the
  drift alarm that would have caught the open-webui DNS bug.
- Keep the extra-GPU template formula (PORT=11438+INDEX) in sync with the
  docs/gpu-assignment.md table.

## Phase 3 — deepseek-harness open issue (parked, not fixed)

The de-patched image builds and dsh starts (prints the token URL on
127.0.0.1:3105) but then crashes: "user patch-layer watching requires the
Cordis HMR service" (dsh-app-boot watchUserPatches, profile-boot
line ~271). Upstream web profile has patchReload: live and the HMR plugin
auto-load path fails under this boot composition. Options, in order of
preference:
1. Check upstream README "Profiles": set the profile's patchReload to
   `startup` (profile package.json dsh.profile) so the live watcher never
   starts. Find where the web profile bundle declares patchReload.
2. Try running the stock `dsh web` entrypoint (no --expose-internals
   wrapper) — the operator suspects the flag is not what makes HMR work;
   the crash happens with AND without it, so the wrapper may be unnecessary
   entirely. Simplify docker-entrypoint.mjs to `exec dsh web --port ...`
   if plain dsh works.
3. Try a newer dsh release (npm view @deepseek-ai/dsh versions).
Until fixed: the service stays stopped (it is opt-in anyway); the plugin
shows it as stopped. Do NOT re-add the old bridge to mask this.

## Phase 4 — plugin consolidation

- Move the plugin source from ~/Documents/ryoku-plugins/ailab into the
  repo as `plugin/ailab/` (single source of truth), keep the authoring
  copy as a symlink or just work from the repo path with
  `ryoku plugin add plugin/ailab --bar --yes`.
- bin/ai-lab wrapper: default AI_LAB_REPO should resolve relative to the
  installed plugin when possible; keep the env override.
- Capture assets/preview-widget.png (bar screenshot) and list it in
  manifest files — required before any `ryoku plugin share`.
- README: add an "AI Lab bar plugin" section (what it shows, settings,
  QS Bar Settings > Community, how to install/remove).
- Do NOT run `ryoku plugin share` unless the operator asks to publish.

## Phase 5 — uninstall + install smoke

- uninstall.sh: verify it removes strata, hyperframes, the ailab plugin
  (`ryoku plugin remove ailab`), the masked
  podman-user-wait-network-online.service (unmask), and the systemd-ai
  network; keeps config/ and data volumes per its own docs.
- Full fresh-install smoke in a clean user context (or at least
  `install.sh --dry-run` + review): install must end with all boot
  services healthy on 31xx/1143x, research stopped, hermes/dsh absent,
  zero failed units, and `ai-lab status` agreeing with systemctl.
- Reboot check (or `systemctl --user daemon-reload && restart of all`):
  boot-enablement must match services.json "boot" flags exactly.

## Phase 5b — security audit

Baseline from the 2026-10-05 scan (re-run everything; findings may change):
no secrets in tracked files, no hex blobs in git history, no hostname/LAN-IP
leaks, .gitignore covers config/*/service.env, keys.txt, presets.ini and
generated quadlets. Remaining gaps to close:

1. Gitignore gaps (untracked-but-committable today):
   - config/strata/ (new, untracked, NOT ignored) — add to .gitignore if it
     holds machine-specific config; commit only *.example.
   - Any future config/<svc>/service.env variant: verify the glob still
     matches nested additions (config/*/service.env is one level deep only).
   - tests/ fixtures: ensure no test ever writes a real key into a tracked
     file (generate-secrets test output goes to a temp dir).
2. History hygiene (belt and braces):
   - Re-run: `git log --all -p | grep -E '[0-9a-f]{40,}'` and
     `git grep -I 'KEY\|SECRET\|TOKEN' $(git rev-list --all)` before the
     first push of the restructured tree. Repo remote is SSH/private, but
     the README advertises curl|bash from raw.githubusercontent — assume
     the repo may go public one day.
   - If any hit ever appears: rotate the credential (treat as burned),
     do not just delete the file.
3. Credential lifecycle:
   - scripts/generate-secrets.sh: confirm every secret is freshly random
     (openssl rand -hex), never a fallback constant; keys.txt mode 600.
   - Add `just rotate-secrets` (or a script) that regenerates
     WEBUI_SECRET_KEY + llama keys.txt and restarts affected services —
     today a leaked key has no documented rotation path.
   - README token section (dsh): note the token in `podman logs` is
     sensitive; logs stay on the host journald.
4. Network exposure review (README firewall section currently opens all of
   3100-3104 + 11435-11437 on the LAN):
   - sketchlab's LLM endpoint and hyperframes' render API are
     UNAUTHENTICATED on the LAN; llama-cpp-main is key-protected; comfyui
     is unauthenticated. Document per-service auth status in the README
     table and services.json (add an "auth" field: none|api-key|token).
   - Decide deliberately: keep LAN exposure (home-LAN trust model) or
     rebind to 127.0.0.1 + an explicit opt-in for LAN. Record the decision
     in docs; do not leave it implicit.
   - strata is loopback-only (frozen) — keep the README table honest about
     that (the deployed unit binds 127.0.0.1 even though
     quadlets/strata.container.in says 0.0.0.0; reconcile the .in file to
     match reality WITHOUT touching the deployed unit).
5. Supply-chain pins:
   - Containerfiles: node base images are digest-pinned (good); check the
     rest (open-webui tag v0.11.3, llama.cpp server-cuda tag, hermes-agent
     :latest) — pin :latest images to digests in services.json so rebuilds
     are reproducible.
   - hyperframes image is built from a local clone: record the upstream
     commit (currently f70dce7) in docs or services.json notes.
6. Plugin surface: the ailab plugin runs unsandboxed as the user; its only
   external commands are systemctl --user/curl/python3 (validated). Keep
   capabilities honest in manifest.json if the CLI grows commands.
7. Caddy leftovers: config/caddy holds TLS/mkcert references — fine as
   reference, but ensure install.sh never copies certs into $CONFIG_DIR
   and the docs say the Caddyfile is NOT deployed.

Gate: `git ls-files | xargs grep -lE 'secret|key|token'` review passes,
history scan clean, every generated secret file mode 600 and ignored,
README exposure table matches services.json auth fields.

## Phase 6 — housekeeping

- ~/.local/share/llama.cpp/models/ is empty: router serves nothing. Either
  run scripts/download-gguf-series.sh (262144-token presets per operator
  preference) or document that models are downloaded on demand.
- Remove the stale `systemd-llama-cpp.service` not-found unit reference
  seen in old `systemctl status` output (leftover from pre-rename era;
  verify nothing still Wants= it).
- docs/: merge port-plan.md findings into README's port table once stable;
  keep gpu-assignment.md's extra-router ports as 11438+N.
- Test runner: run tests/*.sh directly (no justfile).

## Verification checklist (final gate)

[ ] git status clean; no secrets tracked
[ ] tests/ all pass, including new registry-consistency test
[ ] ai-lab status: 6 running (main, strata, webui, comfyui, sketchlab,
    hyperframes), 3 stopped (research, hermes, dsh), 0 failed units
[ ] every service answers on its services.json port
[ ] install.sh summary / README / docs all agree with services.json
[ ] plugin visible on bar, toggles work, validate clean
[ ] uninstall.sh dry-run leaves nothing stale
[ ] security gate passed: no secrets tracked or in history, secret files
    mode 600 + gitignored, exposure table + auth fields documented
