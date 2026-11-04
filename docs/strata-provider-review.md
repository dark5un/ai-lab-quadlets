# strata-provider — security & public-release review (2026-11-04)

Scope: `containers/vscode/strata-provider/{package.json,extension.js,README.md}`,
`containers/vscode/entrypoint.sh`, `containers/vscode/Containerfile`,
`quadlets/vscode.container`, `config/vscode/service.env.example`,
`scripts/generate-secrets.sh`, `tests/test-strata-provider.sh`,
`docs/copilot-strata.md`. Commits `cb7d019..3bf053d` (+ history scan of all 157 commits).

## Executive verdict

**The core design is sound.** Stable-API-only extension, secrets env-scoped
(no key in image, repo, or user profile files), loopback-only publish port,
idempotent entrypoint state writes with an honest clobber history, and a live
smoke test. The full git history scan (all commits, all blobs) found **zero
committed secrets or PII beyond the intended author email**: every
`STRATA_API_KEY=`/`API_KEY=` in history is a placeholder or a runtime-read,
`.ts.net` names appear only as `<TAILNET>`, and `config/**/service.env` +
`keys.txt` are gitignored (verified via `git check-ignore`).

Three things block a clean public release, and two are real (defense-in-depth)
security items:

1. **P0**: the serve-web connection token travels in argv (`ps` visibility).
2. **P0**: `strata.baseUrl` / `strata.apiKey` are window-scoped settings while
   the extension auto-attaches the env key → one "Trust Workspace" click on a
   malicious folder can exfiltrate the machine secret.
3. **P1 (hard blocker)**: `vsce` 4.1.0 **refuses to package the extension today**
   (`main` without `activationEvents` — reproduced live), plus the missing
   LICENSE file makes packaging interactive (CI-unsafe), and the README's
   `../../` links render as broken `…/blob/HEAD/../../…` URLs on the details
   page (both reproduced live in a scratch clone).

Note the repo is **already PUBLIC** (`gh repo view`: `PUBLIC`) — history is
clean, so no delete+recreate is needed *for this change set*; re-run the scan
if any of the runtime files below ever change.

Findings count: **P0: 2 · P1: 5 · P2: 8**.

## Findings

| # | Sev | Where | Issue | Exact change |
|---|-----|-------|-------|--------------|
| 1 | P0 | `containers/vscode/entrypoint.sh:103` | `--connection-token "$VSCODE_CONNECTION_TOKEN"` puts the secret in argv: visible to every process in the container via `ps`/`/proc/*/cmdline` (and the container runs a terminal + host-podman access), and in any audit/journal capture of the exec line. | Keep the env var (EnvironmentFile), but at start: `umask 077; printf '%s' "$VSCODE_CONNECTION_TOKEN" > "$HOME/.vscode-server/connection-token"` (dir already persisted), then replace `--connection-token "$VSCODE_CONNECTION_TOKEN"` with `--connection-token-file "$HOME/.vscode-server/connection-token"`. Flag verified present in the pinned 1.144.1: `podman exec systemd-vscode code serve-web --help` lists `--connection-token-file <CONNECTION_TOKEN_FILE>`. (The one-time startup banner still prints `?tkn=` into the journal — unavoidable; rotate via `scripts/rotate-secrets.sh` on suspicion. Token gate itself stays ON — do not use `--without-connection-token`.) |
| 2 | P0 | `containers/vscode/strata-provider/package.json:31-40`; `extension.js:14,17,36` | `strata.baseUrl` and `strata.apiKey` default to **window scope** (no `scope` declared), and `extension.js:36` auto-attaches `Authorization: *** env` key to *whatever* baseUrl says. A malicious repo's `.vscode/settings.json` (applied after the user clicks Trust — the box *asks* to trust on first open) can redirect every chat request + the box's `STRATA_API_KEY` to an attacker host. One click, no code execution required. | Add `"scope": "machine"` to `strata.baseUrl`, `strata.apiKey`, and `strata.modelAllowlist` (contextWindow/maxOutputTokens/toolCalling/imageInput can stay window). Then the box must supply baseUrl in the entrypoint's `data/Machine/settings.json` (`entrypoint.sh:85-91`): add `"strata.baseUrl": "http://systemd-strata:8080/v1"` there, and change the *public* package.json default (`:33`) to a sane generic one, e.g. `http://127.0.0.1:8080/v1` (README table `:37` likewise). This also fixes the "internal hostname as public default" smell in one move. |
| 3 | P1 | `containers/vscode/strata-provider/package.json` (no `activationEvents`, has `main:19`) | `@vscode/vsce` 4.1.0 fails packaging outright: `ERROR Manifest needs the 'activationEvents' property, given it has a 'main' property.` **Reproduced live** (scratch copy + clone of this repo). Runtime auto-generates `onLanguageModelChatProvider:<vendor>` (why the box install works without it), but vsce validation requires the property. | Add `"activationEvents": ["onLanguageModelChatProvider:strata"]` to package.json. Then `vsce package` succeeds (verified). |
| 4 | P1 | `containers/vscode/strata-provider/` (no LICENSE); repo-root `LICENSE` exists | vsce's `LicenseProcessor` only accepts a license file matching `extension/licen[cs]e(.md|txt)?` — the *extension folder*, not the repo root (source: microsoft/vscode-vsce `src/package.ts`, fetched). Without it, packaging prints `LICENSE, LICENSE.md, or LICENSE.txt not found` and **prompts interactively** — breaks CI publishing (`--skip-license` exists but ships an unlicensed listing that contradicts `"license": "MIT"` at package.json:7 and README:86). | Create `containers/vscode/strata-provider/LICENSE` (MIT text, same as repo root). Verified: with the file present, vsce packages it as `extension/LICENSE.txt` and embeds it in the VSIX manifest — no prompt, no flag needed. |
| 5 | P1 | `containers/vscode/strata-provider/README.md:81,86` | Relative links leaving the extension folder (`../../docs/copilot-strata.md`, `../../LICENSE`) are rewritten by vsce (repository auto-detect, per publishing docs) to **`https://github.com/dark5un/ai-lab-quadlets/blob/HEAD/../../docs/copilot-strata.md`** — reproduced live; the `repository.directory` field does not fix this. Broken on the details page. | Use absolute GitHub URLs (`https://github.com/dark5un/ai-lab-quadlets/blob/main/containers/vscode/strata-provider/README.md#…` or the docs path) or drop the out-of-folder links from the Marketplace README. Keep the `Niko1221/Strata` link (absolute — untouched, verified). |
| 6 | P1 | `extension.js:102-104` | `Object.assign(body, options.modelOptions)` lets caller-/setting-supplied `modelOptions` **override `model`, `messages`, and `stream`**. `stream:false` silently yields an empty answer (SSE loop finds no `data:` lines); arbitrary extra fields pass through to the endpoint — on llama.cpp-class servers e.g. `path` can load a different GGUF. Input sources are user settings (machine-scope after fix #2) and chat participants — acceptable for a local trust boundary, but core fields should not be overridable. | Build the body protectively: `const body = Object.assign({}, (options && options.modelOptions) \|\| {}); body.model = model.id; body.messages = convertMessages(messages); body.stream = true;` (re-pin last). Document in README that remaining passthrough fields go verbatim to the endpoint (OpenAI-compatible extras like `temperature`, `top_p`, `seed` are the intended use). |
| 7 | P1 | `package.json:2-4` + Marketplace policy | Extension `name` must be **unique to the Marketplace** (extension-manifest reference, fetched) and removed names are **permanently reserved** (publishing-extension page, fetched). `strata-provider` locks in a brand nobody searches for, while the extension fronts *any* OpenAI-compatible server (README:3-4 says so). Open VSX additionally enforces namespace-similarity/typosquat checks. | Decide branding **before first publish** (renaming later costs the ID forever). Recommendation: `name: "openai-compatible-models"`, `displayName: "OpenAI-Compatible Local Models (BYOK)"`, provider `displayName` "OpenAI-Compatible (local)"; keep keyword `"strata"`; keep the `strata.*` settings namespace and vendor id `strata` for v0.x to avoid breaking box installs (entrypoint folder id `dark5un.<name>` — update `entrypoint.sh:39,44,57-65,72` + `tests/test-strata-provider.sh:23` in the same commit if `name` changes; the vendor string, not the folder id, keys the picker). Tradeoff: "OpenAI" in a name risks a naming-policy query (Marketplace blocks *confusingly similar to popular publishers/extensions* — "OpenAI-compatible" is an established category phrase, low risk; the vendor OpenAI itself publishes under other names) vs "Strata" = zero discoverability + strata-project confusion. Net: generic naming wins. |
| 8 | P1 | `entrypoint.sh:38` | Extension version parsed with `sed` on the first `"version"` string anywhere in package.json — silently wrong if any earlier field ever contains `"version": "…"` (e.g. a devDependencies block). | Use jq (already in the image): `ver=$(jq -r .version "$SRC/package.json")`. |
| 9 | P2 | `extension.js:48` | Error text embeds `${url}` + first 400 chars of the response body in chat UI. For 401s from *your own* endpoint this leaks nothing sensitive (llama.cpp-class servers don't echo keys — assumed), and debuggability is worth it. | Keep; optionally redact the URL's userinfo/query: `new URL(url).origin + new URL(url).pathname`. No action needed beyond a README line. |
| 10 | P2 | `extension.js:225` | Every image DataPart is re-base64-encoded **per request** and resent with each turn (quadratic bytes over an image-heavy chat); no size cap → memory spike + request-size DoS toward the local server. | Add `strata.maxImageBytes` (default ~10 MB, setting #2-scope: window is fine here): skip + `progress.report` a text notice for larger images; consider dedupe by content hash later. Document the passthrough in README Limitations. |
| 11 | P2 | `extension.js:173` | `slot.name += tc.function.name` accumulates; servers that repeat the full name in every delta (known llama.cpp-compat quirk class — assumed, not observed on strata here) produce `calculatorcalculator…`. | `if (tc.function.name && !slot.name.includes(tc.function.name)) slot.name = tc.function.name;` or set-once. Keep index-keyed accumulation (it's correct for chunked names). |
| 12 | P2 | `scripts/generate-secrets.sh:136` | `sed -i "s\|...\|STRATA_API_KEY=${sk}\|"` — a key containing `&` or `\|` corrupts/injects into the sed replacement. Generated keys are hex (safe today) but `install-strata.sh:88` users can hand-edit. | Replace with `awk -v k="$sk" '/^STRATA_API_KEY=/{print "STRATA_API_KEY=" k; next} 1' "$dst" > "$dst.tmp" && mv "$dst.tmp" "$dst"`. (Everything else in the script is good: umask 077, 700/600 modes, never prints values.) |
| 13 | P2 | `tests/test-strata-provider.sh:19` | Real key passed as `podman exec -e STRATA_API_KEY="$KEY"` → visible in host `ps`/journald during the run. Dev-box-only blast radius. | `podman exec -i --env-file "$ENVFILE" systemd-vscode bash -s <<…` (passes both vars without argv exposure; drop lines 16-17 or keep for the presence check only). |
| 14 | P2 | `entrypoint.sh:54-74` | Manifest re-registration rewrites our `extensions.json` entry (new `installedTimestamp`) **every start** and would also overwrite a gallery-installed entry of the same id — intentional on this box, but if public users install from Marketplace *on this box*, the image-baked copy wins silently. Also `mv "$tmp" "$MANIFEST"` is not atomic across the jq-read (no concurrent writer exists — runs before `exec code serve-web` — so fine). | Keep as-is for the box; document the precedence in README's stack note. After public publishing, switch the box to a gallery install and gate the entrypoint block behind `[ -f "$MANIFEST" ] && jq -e 'any(.identifier.id=="dark5un.…")'` — or simply leave the bake (deterministic; recommended). |
| 15 | P2 | `quadlets/vscode.container:33` + `entrypoint.sh:101` | Publish is loopback-only (good). But `--host 0.0.0.0` inside makes serve-web reachable from every container on `ai.network` — token still gates it (unverified hardening claim: all requests require the secret, per `serve-web --help` "A secret that must be included with all requests" — that IS the help text, so: gated by token, fine). `SecurityLabelDisable=true`/`:Z` are SELinux no-ops on Arch — harmless. | No change; add a one-line comment in the quadlet noting the token gate covers the ai.network surface. |
| 16 | P2 | details-page polish | No `icon` (manifest ref: ≥128×128 px, 256×256 Retina recommended), no `galleryBanner`, no CHANGELOG.md (Marketplace renders it), no `bugs`/`homepage` fields, no `"files"` array (vsce warns: "Neither a .vscodeignore file nor a \"files\" property was found" — reproduced live), `"pricing": "Free"` is the default (harmless, keep or drop). | Add `icon: "icon.png"`, `CHANGELOG.md`, `"bugs": {"url": "https://github.com/dark5un/ai-lab-quadlets/issues"}`, `"files": ["extension.js", "icon.png"]`. Optional UX: `managementCommand` on the provider contribution (official provider guide) that prompts for a key via `showInputBox({password: true})` and stores it in `context.secrets` (SecretStorage) instead of the plaintext setting — worth doing before GA; plaintext settings also flow through Settings Sync if a user puts the key there. |

### What is already right (keep)

- No secret ever baked into image/Containerfile/repo; `STRATA_API_KEY` rides
  the quadlet `EnvironmentFile` → `process.env` only (`extension.js:17`).
- Machine-scope `data/Machine/settings.json` written wholesale for box policy
  (never user-editable state) — the right layer; v1's user-file seeding drift
  and secret-at-rest problems were correctly retired (`entrypoint.sh:24-32`).
- Workspace trust left ON; token gate intact; loopback publish; telemetry off.
- SSE tool-call reassembly by index, `[DONE]`/keepalive tolerance, abort
  wiring via `onCancellationRequested` (`extension.js:26-30,126-198`) — clean.
- Header-clobber fix (`fetchJson` merges `opts.headers` *before* setting
  Authorization, `extension.js:33-38`) — correct pattern.
- History hygiene: gitignored generated envs, `<TAILNET>` placeholders
  everywhere, no 64-hex literal ever added in any commit (scanned).

## Publishing runbook (Marketplace first, OpenVSX mirror)

Fact-checked against code.visualstudio.com (publishing-extension, extension-manifest,
language-model-chat-provider) and the microsoft/vscode-vsce source; latest
`@vscode/vsce` on npm at check time: **4.1.0** (`npm view`).

0. **Pre-flight decisions**: extension `name` is permanent once removed —
   resolve #7 first. Confirm publisher id `dark5un` is free at
   https://marketplace.visualstudio.com/manage (Create publisher → identifier +
   name; a Microsoft account is the auth base; PAT created under that account
   with "all accessible accounts" scope, or skip PATs entirely via step 5).
1. Apply fixes #2-#6, #8, #16; bump `version` to `0.2.0`; verify the box
   still smoke-passes: `tests/test-strata-provider.sh`.
2. Package (works with **no build step** — single CommonJS file, zero deps;
   reproduced): `cd containers/vscode/strata-provider && npx @vscode/vsce@4.1.0 package --no-yarn`
   → `openai-compatible-models-0.2.0.vsix`. Expect zero warnings once LICENSE +
   activationEvents + files are in. Do not commit the `.vsix` (add to
   `.gitignore` in the release commit). vsce's own secret scanner blocks
   packaging on `.env`/secret patterns — none trigger on these files (observed).
3. Publish: `npx @vscode/vsce publish` from the extension dir (PAT via
   `vsce login dark5un` once, or `VSCODE_PAT` env), or manually upload the VSIX
   on the publisher management page. Marketplace then runs malware scan,
   **secret scanning** (publish blocked on hits), name-squat checks, and
   **signs the extension automatically** (repository signing — nothing to do;
   VS Code verifies at install). Publisher-side signing (`vsce --sign-tool`,
   signature reports) is optional/advanced — skip for 0.2.0.
4. Open VSX mirror (required for VSCodium/derive users): register at
   open-vsx.org (GitHub login), `npx ovsx create-namespace dark5un -p <token>`,
   then `npx ovsx publish openai-compatible-models-0.2.0.vsix -p <token>`.
   Open VSX enforces its own secret scan, blocklist, and namespace-similarity
   checks (wiki, fetched).
5. Optional CI (later): GitHub Actions Trusted Publishing — create a policy on
   the publisher page (owner `dark5un`, repo `ai-lab-quadlets`, workflow file,
   optional environment), job needs `permissions: {id-token: write}`, step:
   `npx @vscode/vsce publish --oidc` (docs, fetched). Same workflow can push
   Open VSX via `HaaLeo/publish-vscode-extension`. Native-tooling-only rule
   respected: no lockfiles, no bundler, `npx @vscode/vsce` ad hoc.
6. Details-page caveat checklist: README renders the details page (absolute
   links only after fix #5); add CHANGELOG.md; the `ai-lab stack note` section
   is fine to keep — internal *aliases* like `systemd-strata` as a documented
   example are acceptable, they must not be the default after fix #2.

## Verified vs assumed

**Verified (primary source or live check this session):**
- Repo visibility: `gh repo view` → PUBLIC. History scan: `git log --all -p`
  + `git grep` over every rev for 64-hex/`KEY=`-hex/`tkn=`/`sk-`/JWT/`100.x`
  IPs → no real secrets; only templates, placeholders, `openssl rand` calls
  (`generate-secrets.sh:32`, `install-strata.sh:88`); `.gitignore` covers
  `config/**/service.env`, `keys.txt` (`git check-ignore` confirmed).
- `--connection-token-file` exists in pinned 1.144.1: `podman exec
  systemd-vscode code serve-web --help` (run live in the container).
- `code serve-web --help`: "--connection-token … A secret that must be included
  with all requests" (token gate is global, incl. ai.network reachers).
- vsce 4.1.0 latest on npm (`npm view @vscode/vsce version`).
- vsce hard error without `activationEvents` (reproduced twice: scratch + repo clone).
- LICENSE must be in the extension folder; interactive prompt without it; with it,
  packaged as `extension/LICENSE.txt` + VSIX `<License>` (vsce source + reproduced).
- README `../../` links rewrite to `/blob/HEAD/../../` (inspected VSIX
  `extension/readme.md` from the clone — broken).
- `.vscodeignore`/`files` warning (reproduced). No icon → no error (reproduced).
- Marketplace: name unique Marketplace-wide; removed names permanently reserved;
  repository auto-link-adjustment default branch `main`; ≤30 keywords; Trusted
  Publishing via GitHub Actions OIDC (`--oidc`); publisher creation flow; Azure
  DevOps auth base (publishing-extension + extension-manifest docs, fetched).
- Marketplace protections: automatic repository signing at publish, malware +
  secret scanning, name-squatting prevention, verified-publisher badge rules
  (code.visualstudio.com docs + MS dev blog, fetched).
- Open VSX: namespace must be created; `ovsx publish` uses vsce internally;
  secret/blocklist/namespace-similarity scanning (openvsx wiki, fetched).
- Provider API shape incl. optional `managementCommand`, `silent` semantics,
  `capabilities.toolCalling: boolean|number` (official provider guide .md, fetched).
- `engines.vscode` full-semver requirement + scanner rejection of `^1.104`:
  repo's own live-scarred claim (commit 07dd9db) — consistent with docs; taken as
  owner-verified.

**Assumed (label; cheap to confirm later):**
- llama.cpp-class 401 bodies do not echo the bearer key (basis for #9 staying P2).
- Some OpenAI-compatible servers repeat `tool_calls[].function.name` per delta (#11).
- Marketplace naming filter tolerates "OpenAI-Compatible …" as a category phrase
  (it targets confusion with popular publishers/extensions; not tested pre-publish).
- serve-web's startup journal line contains `?tkn=<token>` (stated in the parent
  context; not re-derived here).
- Settings Sync replicates plaintext settings (including a user-set
  `strata.apiKey`) to the user's sync account (standard behavior; not
  separately re-verified this session).
- Exact `ovsx` CLI spelling of `create-namespace` (wiki page truncated mid-steps;
  `ovsx --help` at publish time settles it).
