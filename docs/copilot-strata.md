# Copilot ↔ Strata: binding the VS Code Server box to the local model (research, 2026-11-03)

Question: can the VS Code Server (`systemd-vscode`, VS Code 1.144.1 web +
Arch dev box) run its GitHub Copilot experience against **strata** (our
local OpenAI-compatible server at 11434) instead of GitHub's cloud models?

Short answer: **yes for chat/agent mode — first-party, no extra plugin
needed** — via VS Code's built-in **Custom Endpoint** BYOK provider, which
works against any Chat-Completions endpoint and needs no Copilot plan.
**No for inline ghost-text completions**: those stay on GitHub's cloud, a
known open gap. Details and the exact config for our box below.

## 1. Ground truth probed live on this box (2026-11-03)

These are our own measurements, not external claims:

- strata `GET /v1/models`: id `qwen3.8-flash-next-iq3_s` (slash-free —
  good, see §4 pitfall), `n_ctx: 1048576` (the 1M variant is what's
  currently running), input modalities `text+image` per the model card.
- **Tool calling works**: an OpenAI `tools=[calculator]` round-trip
  returned `finish_reason: "tool_calls"` with a well-formed function call.
- **Streaming works**: SSE chunks from `/v1/chat/completions stream:true`.
- The box reaches strata over the stack network:
  `http://systemd-strata:8080/v1/models` returns the model list **from
  inside `systemd-vscode`**. Host loopback (127.0.0.1:11434) is NOT
  reachable from the container netns — always use the `ai.network` name.
- strata responses carry `reasoning_content` (thinking) alongside tool
  calls — relevant to the empty-response trap in §4.

So strata satisfies the documented model requirements for Copilot
surfaces: tool calling + streaming + big context (the CLI's bar: tool
calling, streaming, 128k+ recommended).[3]

## 2. The first-party path: Custom Endpoint BYOK in VS Code

VS Code's BYOK ("bring your own language model key") lets you add models
from other providers while keeping the VS Code chat experience and
tools.[1] The **Custom Endpoint provider** is the official way to connect
any compatible API endpoint; it replaces the deprecated OpenAI Compatible
provider and the `github.copilot.chat.customOAIModels` setting.[1] It
shipped in stable VS Code 1.122+,[12] so our 1.144.1 server has it — the
old Insiders-only gating (which community unlocker extensions existed to
bypass[11]) is not a concern anymore.

Key scope facts, straight from the docs:

- BYOK models work **without signing into a GitHub account and without a
  Copilot plan**, including offline scenarios with local models.[1][2]
  Requests go directly to your provider, not through GitHub's Copilot
  API.[2]
- BYOK applies to chat, agent mode, inline chat and utility tasks;
  **inline suggestions (ghost text), semantic search and embeddings
  still require GitHub Copilot**.[1][13] The ghost-text gap is an open
  feature request (microsoft/vscode#318545): custom IDs set as completion
  models are silently ignored and fall back to the cloud model.[6]
- Agent mode only lists models that support tool calling; set
  `"toolCalling": true` on the model entry.[7][12]
- If your plan is Copilot Business/Enterprise, BYOK can be disabled by an
  org policy — not our case (personal use).[1][2]

Feature matrix for what strata can take over inside the box (supported =
BYOK works there):

| Copilot capability | On strata via BYOK | Notes |
|---|---|---|
| Chat panel | yes | chat-completions API[1] |
| Agent mode in chat | yes | needs tool-calling model[1][7] |
| Inline chat (`Ctrl+I`) | yes | `inlineChat.defaultModel`[1] |
| Commit messages / PR text / titles | yes | point `chat.utilityModel` / `chat.utilitySmallModel` at strata[1][7] |
| Agent Host sessions | experimental | `chat.agentHost.byokModels.enabled`[7] |
| Inline code completions (ghost text) | **no** | GitHub cloud only[1][6][13] |
| Semantic workspace search / embeddings | **no** | needs Copilot[1][13] |

## 3. Exact config for this box

**SETUP IS AUTOMATED (2026-11-04)**: the box entrypoint seeds this file at
first start from `STRATA_API_KEY` in the on-target env file
(`config/vscode/service.env`, copied there by `generate-secrets.sh` from
`config/strata/service.env` — sketchlab's pattern). No secret ever
enters the image, the Containerfile, or this repo. The seeded file lives
in the persisted home (`~/.vscode-server/data/User/chatLanguageModels.json`,
mode 600); after first seed the box owns it and UI edits win. The
alternative UI path (wizard + secret storage) remains:
Command Palette → **Chat: Manage Language Models** → **Add Models →
Custom Endpoint**. In that path, VS Code stores the key you paste at the
prompt in secret storage and writes a `${input:...}`
reference — enter the key in the wizard rather than pasting it into the
JSON, per Coder's guide.[12] Note the vendors conflict on this: a
MindsHub test on VS Code 1.131 saw the secret reference passed through
unexpanded (401s), and treated a literal key as the working form there;
retest if requests arrive without an Authorization header.[14]) The generated `chatLanguageModels.json`
should end up like:

```json
[
  {
    "name": "strata",
    "vendor": "customendpoint",
    "apiKey": "${input:chat.lm.secret.XXXXXX}",
    "apiType": "chat-completions",
    "models": [
      {
        "id": "qwen3.8-flash-next-iq3_s",
        "name": "Strata (local 5090)",
        "url": "http://systemd-strata:8080/v1/chat/completions",
        "toolCalling": true,
        "vision": true,
        "thinking": true,
        "contextWindow": 1048576,
        "maxOutputTokens": 16384
      }
    ]
  }
]
```

Notes on the fields (all from the docs/config reference):

- `url` must be the **full** chat-completions path, not just `/v1` — the
  most common setup-breaker for this provider.[13]
- `contextWindow` (1M here, matching the live model card) lets VS Code
  derive `maxInputTokens` itself; a 1M-token example is in the official
  property reference.[1]
- `vision: true` per the model card's input modalities; not exercised
  end-to-end yet — flip to `false` if image requests misbehave.
- `chatLanguageModels.json` lives in the box's **user config** (server
  side, under the persisted home) — it survives rebuilds, and the strata
  key itself is in secret storage, never in this repo.
- Reload the window after saving; the model picker populates at
  startup.[7][12]
- **Gotcha hit live (2026-11-04): the Agent Host (the default session
  type in 1.14x) hides BYOK models unless
  `chat.agentHost.byokModels.enabled` is true — default false — so
  selecting strata silently reverts to Auto/Copilot.** VS Code's settings
  reference confirms the key and its `false` default. The entrypoint now
  guarantees the key (adds it if absent, respects an explicit `false`).

Then, for the utility features (title generation, commit messages, PR
descriptions) to also run local, override the utility model settings
with any available model, including BYOK ones:[1]

- `chat.byokUtilityModelDefault: Main Agent Model`, or
- `chat.utilityModel` / `chat.utilitySmallModel` → the strata entry.[1]

Operational: strata is an on-demand GPU unit outside the arbiter for
vscode itself — an agent session from the box needs strata RUNNING
(`ai-lab start strata` / the boot variant). If strata gets moved by the
arbiter when another GPU service starts, chat requests fail until it is
back — normal stack behavior, just be aware.

## 4. Pitfalls worth pre-arming (sourced)

- **Model IDs containing `/` are rejected by the custom-endpoint
  client** (per Lyceum's guide; they publish slash-free aliases). Our
  strata ID is already slash-free.[7]
- **Reasoning models can return empty bubbles**: the visible answer and
  reasoning can share the output budget — strata emits
  `reasoning_content` (our probe saw it), so keep `maxOutputTokens`
  generous (16k+) and check `finish_reason` when the UI shows blank
  responses.[7]
- Copilot sends `temperature: 0.1` for custom endpoints unless the model
  entry overrides it via `modelOptions`.[14]
- If agent mode hides the model: `toolCalling` missing or stale JSON —
  VS Code reads the file at startup, restart to apply.[12]

## 5. Other surfaces that can bind to strata (not just VS Code)

- **GitHub Copilot CLI**: user-configured BYOK with `openai` provider
  type = "any OpenAI Chat Completions API-compatible endpoint"; requires
  tool calling + streaming; 128k+ context recommended; env:
  `COPILOT_PROVIDER_BASE_URL=http://systemd-strata:8080/v1`,
  `COPILOT_PROVIDER_API_KEY`, `COPILOT_MODEL=qwen3.8-flash-next-iq3_s`;
  `COPILOT_OFFLINE=true` keeps it from contacting GitHub at all.[3]
  Runs inside the box's fish terminal — effectively a local Copilot
  agent. (Note the base URL here is the `/v1` form, unlike the full
  path the VS Code provider needs.[13])
- **GitHub Copilot app**: supports "any OpenAI-compatible HTTP
  endpoint" for BYOK (public preview); GitHub sign-in is still required
  but not a Copilot plan.[4]
- **Model-provider extensions** as an alternative bridge: "OAI
  Compatible Provider for Copilot" (marketplace) injects
  OpenAI/Ollama/Anthropic/Gemini endpoints into the Copilot Chat picker
  with per-model families and custom headers[5] — mostly useful where
  the built-in Custom Endpoint lacks a feature; redundant for us now.

## 6. The ghost-text gap: options if you want completions local too

None of these use "Copilot" for completions; they replace that lane:

1. **Keep Copilot cloud completions** and run chat/agent on strata —
   hybrid, zero extra moving parts (the pragmatic default).
2. **Tabby**: self-hosted completion server whose model connectors speak
   `llama.cpp/completion` (FIM) and `openai/chat` for its chat side;
   its VS Code client contributes the inline suggestions.[10] Needs a
   dedicated FIM model — qwen3.8-next is a chat model, so strata is a
   poor completions backend; a small coder model (e.g., Qwen2.5-Coder
   class) on the 4070 Ti/CPU via the existing llama-cpp units is the
   right shape.
3. **Continue.dev**: config `provider: openai` + `apiBase` covers chat/agent
   against strata,[8] but its autocomplete role explicitly needs a
   fill-in-the-middle model — "chat models, though larger, will often
   perform poorly" for autocomplete.[9]

Follow-up candidates (deferred, not part of this research): a small
Qwen-Coder FIM llama.cpp quadlet + Tabby (or Continue's
tabAutocompleteModel) to make ghost text local too.

## 7. Verdict

Bind Copilot Chat + Agent in the box to strata through the built-in
Custom Endpoint provider (§3) — it is first-party,[1] ships in stable
since 1.122,[12] works against local models without a GitHub sign-in or
Copilot plan,[1][2] and strata already passes every documented model
requirement (§1 probes; tools + streaming per the CLI's stated bar,[3]
1M ctx live). Ghost-text completions and embeddings remain GitHub-side
until microsoft/vscode#318545 lands;[6] option 1 (hybrid) until a
dedicated FIM model exists in the stack.

## Sources


[1] https://code.visualstudio.com/docs/agent-customization/language-models — AI language models in VS Code (official docs)
[2] https://docs.github.com/en/copilot/concepts/models/bring-your-own-key — Bring your own key for GitHub Copilot (concepts)
[3] https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models — Adding LLM models to GitHub Copilot CLI
[4] https://docs.github.com/en/copilot/how-tos/github-copilot-app/use-byok-models — Adding LLM models to the GitHub Copilot app
[5] https://marketplace.visualstudio.com/items?itemName=johnny-zhao.oai-compatible-copilot — OAI Compatible Provider for Copilot (marketplace)
[6] https://github.com/microsoft/vscode/issues/318545 — Support BYOK/Custom Models for Inline Code Completions (open issue)
[7] https://lyceum.technology/magazine/how-to-use-lyceum-models-in-github-copilot/index.html — How to Use Lyceum Models in GitHub Copilot (vendor guide)
[8] https://docs.continue.dev/customize/model-providers/top-level/openai — Continue: OpenAI-compatible provider config
[9] https://docs.continue.dev/customize/model-roles/autocomplete — Continue: autocomplete role (FIM)
[10] https://tabby.tabbyml.com/docs/references/models-http-api/llama.cpp — Tabby: llama.cpp model HTTP API
[11] https://github.com/zqcli/enable-copilot-customoai — enable-copilot-customoai (legacy CustomOAI unlock)
[12] https://coder.com/docs/ai-coder/ai-gateway/clients/vscode.md — Coder AI Gateway: VS Code Custom Endpoint (1.122+ stable)
[13] https://docs.xkiro.com/guides/tools/vscode — xKiro: VS Code Custom Endpoint BYOK scope
[14] http://docs.mindshub.ai/inference/vscode — MindsHub: VS Code Custom Endpoint guide
