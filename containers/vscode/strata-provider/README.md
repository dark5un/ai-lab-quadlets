# Strata Local Models

Contributes models from [Strata](https://github.com/Niko1221/Strata) — or any
OpenAI-compatible Chat Completions server — to the VS Code Chat model picker
and agent mode, using VS Code's **stable Language Model Chat Provider API**
(`vscode.lm.registerLanguageModelChatProvider`). No third-party bridge, no
Copilot plan and no GitHub sign-in are required to chat with your local model:
BYOK requests go straight from the extension host to your endpoint.

## Features

- **Live discovery** — models are read from `GET {baseUrl}/models` on demand,
  so endpoint changes (new model id, new context slot) need zero reconfiguration.
- **Capability mapping from server metadata** — when the server reports
  `meta.n_ctx` and `architecture.input_modalities` (Strata does), the context
  window and vision support of each model are derived automatically.
- **Agent-mode ready** — full OpenAI `tools` / `tool_calls` round-trip
  (streamed argument fragments are reassembled) and `toolMode: Required`
  support; tool-calling is declared so agent mode lists the models.
- **Streaming** — SSE chunks are forwarded to the chat UI as they arrive.
- **Vision passthrough** — image inputs are sent as `image_url` data URIs
  when the endpoint declares image modality.
- **Zero dependencies** — one plain CommonJS file on Node built-ins only.

## Requirements

- VS Code ≥ 1.104 (Chat's provider API; works in desktop, remote and
  `serve-web` setups — the extension runs on the server side via
  `extensionKind: workspace`).
- An OpenAI-compatible Chat Completions endpoint with streaming
  (`stream: true` SSE) — and, for agent mode, working tool calling.

## Settings

| Setting | Default | Purpose |
|---|---|---|
| `strata.baseUrl` | `http://systemd-strata:8080/v1` | OpenAI base URL of your endpoint |
| `strata.apiKey` | `""` | Bearer token; when empty, `STRATA_API_KEY` is read from the server environment |
| `strata.contextWindow` | `1048576` | Fallback context window when the server omits `meta.n_ctx` |
| `strata.maxOutputTokens` | `16384` | Output budget (keep generous for reasoning backends) |
| `strata.toolCalling` | `true` | Declare tool-calling support |
| `strata.imageInput` | `true` | Fallback vision flag when modalities are absent |
| `strata.modelAllowlist` | `[]` | Optionally expose only these model ids |

The environment fallback makes headless/container setups fully automatic:
the process environment never leaves the machine and nothing is written to
user profile files.

## Usage

1. Install the extension (or load the folder with `--extensions-dir` for testing).
2. Set `strata.baseUrl` (and `strata.apiKey` if you don't inject `STRATA_API_KEY`).
3. Open Chat (`Ctrl+Alt+I`), press the **Models** button, pick a model under
   **Strata (local)**.

## Limitations

- Inline ghost-text completions, semantic search and embeddings are VS Code
  services this extension does not replace — the model here powers chat,
  agent mode, inline chat and (when routed) utility tasks.
- Token counting is an approximation (`chars / 4`); context budgeting is
  therefore slightly conservative.
- `reasoning_content` (thinking) deltas are intentionally not rendered —
  keeping answers clean; the output budget accounts for them.

## Security posture

- Requests go only to `strata.baseUrl`; no telemetry, no third-party calls.
- The API key is read from the environment or the `strata.apiKey` setting and
  is sent solely as the `Authorization: Bearer` header to that host.
- Agent-mode tool confirmation, sandboxing and workspace trust remain
  enforced by VS Code itself.

## ai-lab stack note

This extension ships baked into the `ai-lab-quadlets` VS Code Server dev box:
the image copies it, the container entrypoint installs it into the server
extensions directory, and the box's Agent Host gates
(`chat.agentHost.byokModels.enabled`, `chat.byokUtilityModelDefault`,
`chat.agentHost.allowSignedOutWhenUsable`) are written in server-scope
settings. See [`docs/copilot-strata.md`](../../docs/copilot-strata.md) for
the full design and verification trail.

## License

MIT — see the repository [LICENSE](../../LICENSE).
