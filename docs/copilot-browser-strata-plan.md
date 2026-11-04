# Copilot in the browser client (iPad) + strata — investigation & plan (v0.1, 2026-11-04)

Symptom: in the box opened from the iPad browser, chat showed
"Local · Ni", a send produced a red error, then the session reverted to
Auto/Copilot. Screenshot (`~/.homes/vscode/px/image.png`, 09:02) key
evidence, verbatim error:

```
Error Code: Failed to parse URL from /v1/chat/completions: Invalid URL
    at PH_provided.augmentModelResponse
    (https://vscode-cdn.net/stable-web/<commit>?extensions/copilot/dist/extension.js)
```

## 1. Findings (each backed by evidence taken this session)

F1 — **That chat ran the model call in the BROWSER, not in the box.**
The stack frame is `vscode-cdn.net/stable-web/...` = the Copilot
extension's web bundle executing in the iPad's browser extension host.
VS Code's harness docs define exactly this split: the **Local** harness
"works in VS Code's extension host" tied to the editor window[15], while
the Copilot harness works in the **Agent Host** — a separate process
that runs "next to the workspace... on a remote machine", with the
browser acting as client, never host.[16] The picker read "Local · Ni"
→ the session was on the Local harness.

F2 — **The model entry used was a client-side one with a relative URL**,
not our seeded provider. The URL parsed was `/v1/chat/completions`
(scheme+host missing). Our seed in the box home uses the absolute
`http://systemd-strata:8080/v1/chat/completions`. This matches the
documented #1 setup-breaker for this provider: pasting a path instead
of the full URL.[13] Someone added a "Ni" endpoint on the iPad itself.

F3 — **Even a correct absolute URL cannot work browser-side against
strata today**: a live OPTIONS preflight to strata returns
`204 No Content` from the Python harness (`Server: BaseHTTP/0.6
Python/3.12.15`) with **no Access-Control-Allow-Origin** header, and the
strata config keys (`api_key,args,cwd,exe,gpu,host,model_name,port,...`)
expose no CORS/origin knob. A cross-origin fetch from
`https://ai...:8443` would be blocked by the browser. Verified live
2026-11-04.

F4 — **The in-container Agent Host is real and reachable to strata.**
`~/.vscode-server/data/logs/.../agenthost.log` shows the Agent Host
process running inside the box (bundled
`@github/copilot-sdk-linux-x64` runtime, provider `copilotcli`), and
the box resolves `systemd-strata:8080` over `ai.network` (HTTP 200
chat-completions verified from inside). So Copilot-harness sessions
issued by the Agent Host can use BYOK models with **no CORS and no new
network exposure**.

F5 — **Agent Host BYOK was off during the failing session.**
`chat.agentHost.byokModels.enabled` defaults to false ("Make
extension-provided BYOK models available to the Agent Host") per the
official settings reference; it was enabled + verified in the box
settings at ~09:05, AFTER the 08:55/09:02 session (log dirs
20261104T084524/20261104T085526 predate it). The BYOK model fallback to
Auto was the earlier diagnosis; F1–F3 show the iPad chat was a separate,
browser-side failure mode.

## 2. Decision

Primary: **run the box's chat on the Copilot harness (Agent Host)** —
model calls originate inside the container where `systemd-strata`
resolves and no CORS exists as an issue (F3 avoided entirely).

Fallback (only if Agent Host BYOK doesn't surface the model in the
web client): a tailnet CORS front for strata (Phase 3 below). Explicitly
least-preferred: it adds an exposure surface + browser-stored key for no
capability gain.

## 3. Plan

Phase 0 — DONE (preconditions now true):
- seeded `chatLanguageModels.json` (strata Custom Endpoint, tools/vision/
  thinking true, ctx 1048576) + `STRATA_API_KEY` via the env-file flow
  (commits 9f89197/471e631).
- `chat.agentHost.byokModels.enabled: true` guaranteed by the entrypoint.

Phase 1 — iPad client hygiene (user, 2 minutes):
1. In the iPad's chat: remove the hand-added "Ni"/relative-URL model
   entry (Command Palette → Chat: Manage Language Models on the browser
   client). Browser-side config ≠ box config (F1/F2).
2. Start a NEW chat and check the **session target / harness** — select
   **Copilot** (not "Local"). Docs: harness ≠ model; picking a BYOK
   model does not change the harness, and Local sessions live only in
   the browser[15]; enterprise default since 1.142 routes to Copilot
   harness unless `chat.defaultToCopilotHarness: false`/
   `chat.editor.preferCopilotHarness` re-arm Local[15].

Phase 2 — verify the Copilot-harness BYOK path (agent + user):
1. Confirm the Agent Host sees the model: after a fresh reconnect,
   `podman exec systemd-vscode sh -c 'D=$(ls -t ~/.vscode-server/data/logs | head -1); grep -iE "byok|customendpoint|strata" ~/.vscode-server/data/logs/$D/agenthost.log ~/.vscode-server/data/logs/$D/exthost*/GitHub.copilot-chat/*.log'`
   — expect a BYOK registration mentioning the seeded provider.
2. Watch strata side for real traffic: `journalctl --user -u
   strata-5090-1m --since "-5 min" | grep -i completions` (or an
   ai-lab status delta). A successful turn proves F4 end-to-end.
3. If the picker in the browser still does not list the box-side
   strata model on Copilot-harness sessions: record exact extension
   version + repro, escalate to Phase 3.

Phase 3 — fallback: CORS front + tailnet listener (only if Phase 2 fails;
estimate 1h):
- New quadlet `strata-cors` (caddy, existing stack pattern): reverse-
  proxy `:8444-hostloopback` → `http://systemd-strata:8080` **adding**
  `Access-Control-Allow-Origin: https://ai.<TAILNET>.ts.net:8443`,
  OPTIONS passthrough (preflight).
- `tailscale serve --bg --https=8444 http://127.0.0.1:<caddyPort>`.
- On the iPad, re-add the Custom Endpoint with
  `https://ai.<TAILNET>.ts.net:8444/v1/chat/completions` (full URL this
  time[13]) + the strata key (browser secret storage).
- Redaction: real FQDNs only in on-target config (caddy config.yaml in
  `~/.config/containers/config`, never the repo).
- Accepted risks: strata key stored in iPad browser; strata becomes
  reachable from every tailnet device (still key-gated).

Phase 4 — closing the loop (repo):
- If Phase 2 works: note the harness gotcha ("Local" sessions are
  browser-side; use Copilot harness for box-local BYOK) in
  docs/copilot-strata.md §3 + the entrypoint comment stays as-is.
- If Phase 3 was needed: ship `quadlets/strata-cors.container` +
  services.json entry (`tier: optional`, no gpu field — it proxies) +
  port-plan row 8444-adjacent, gates green.

## 4. Acceptance (final definition of done)

- [ ] iPad chat on a Copilot-harness session, model = "Strata (local
      5090)", answers without flipping to Auto.
- [ ] strata logs show the completion requests during that session.
- [ ] GPU telemetry sanity: tokens/s match strata's 5090 numbers, not
      Copilot cloud latency.
- [ ] No relative-URL entries left in the iPad client's model list.
- [ ] Repo gates green for whatever Phase 3 artifacts were added.

## Sources

[13] https://docs.xkiro.com/guides/tools/vscode — xKiro: VS Code Custom Endpoint BYOK scope
[15] https://code.visualstudio.com/docs/agents/run/agent-harnesses.md — Choose an agent harness (VS Code docs)
[16] https://code.visualstudio.com/docs/agents/concepts/agent-host.md — Agent Host architecture (VS Code docs)
