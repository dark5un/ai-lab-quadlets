# OpenAI-Compatible Local Models (BYOK)

Contributes the models of [Strata](https://github.com/Niko1221/Strata) — or
any OpenAI-compatible Chat Completions server — to the VS Code Chat model
picker and agent mode, using VS Code's **stable Language Model Chat Provider
API** (`vscode.lm.registerLanguageModelChatProvider`). No third-party bridge,
no Copilot plan and no GitHub sign-in are required to chat with your local
model: BYOK requests go straight from the extension host to your endpoint.

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

| Setting | Default | Scope | Purpose |
|---|---|---|---|
| `strata.baseUrl` | `http://127.0.0.1:8080/v1` | machine | OpenAI base URL of your endpoint |
| `strata.apiKey` | `""` | machine | Bearer token; when empty, `STRATA_API_KEY` is read from the server environment |
| `strata.modelAllowlist` | `[]` | machine | Optionally expose only these model ids |
| `strata.contextWindow` | `1048576` | window | Fallback context window when the server omits `meta.n_ctx` |
| `strata.maxOutputTokens` | `16384` | window | Output budget (keep generous for reasoning backends) |
| `strata.toolCalling` | `true` | window | Declare tool-calling support |
| `strata.imageInput` | `true` | window | Fallback vision flag when modalities are absent |
| `strata.maxImageBytes` | `10485760` | window | Skip (with a chat notice) image inputs above this size |

`baseUrl`, `apiKey` and `modelAllowlist` are deliberately **machine-scope**:
the extension auto-attaches your key to every request, so an opened folder
must never be able to point that traffic — and the key — at another host.
For container/server setups the machine value can be written by the server
itself (e.g. in `data/Machine/settings.json` for `serve-web`).

The environment fallback makes headless/container setups fully automatic:
the process environment never leaves the machine and nothing is written to
user profile files. Note that a plaintext `strata.apiKey` setting flows
through Settings Sync if you enable it; the env route avoids that.

## Usage

1. Install the extension (or load the folder with `--extensions-dir` for testing).
2. Set `strata.baseUrl` (machine scope) and `strata.apiKey` if you don't
   inject `STRATA_API_KEY` into the server environment.
3. Open Chat (`Ctrl+Alt+I`), press the **Models** button, pick a model under
   **OpenAI-Compatible (local)**.

## Advanced request options

Anything you pass as `modelOptions` (e.g. from chat participants or the API)
is forwarded verbatim to the endpoint as OpenAI-compatible extras —
`temperature`, `top_p`, `seed`, and server-specific fields. The transport-core
fields `model`, `messages` and `stream` are always re-pinned by this extension
and cannot be overridden.

## Limitations

- Inline ghost-text completions, semantic search and embeddings are VS Code
  services this extension does not replace — the model here powers chat,
  agent mode, inline chat and (when routed) utility tasks.
- Token counting is an approximation (`chars / 4`); context budgeting is
  therefore slightly conservative.
- `reasoning_content` (thinking) deltas are intentionally not rendered —
  keeping answers clean; the output budget accounts for them.
- Image inputs are re-encoded per request and resent with each turn; the
  `strata.maxImageBytes` cap bounds the cost (skipped images produce a chat
  notice). Content-hash dedupe may come later.
- Request errors shown in chat include only the endpoint's origin + path and
  the first 400 characters of the server's response body.

## Security posture

- Requests go only to `strata.baseUrl` (machine-scope, see above); no
  telemetry, no third-party calls.
- The API key is read from the machine setting or the environment and is sent
  solely as the `Authorization: Bearer` header to that host.
- Agent-mode tool confirmation, sandboxing and workspace trust remain
  enforced by VS Code itself.

## ai-lab stack note

This extension ships baked into the [`ai-lab-quadlets`](https://github.com/dark5un/ai-lab-quadlets)
VS Code Server dev box: the image copies it, the container entrypoint installs
it into the server extensions directory and re-registers it on every start —
so a Marketplace-installed copy of the same extension on that box is silently
superseded by the image-baked one. The box's Agent Host gates and the machine
`strata.baseUrl` (stack-internal alias, e.g. `http://systemd-strata:8080/v1`)
are written in server-scope settings. See
[`docs/copilot-strata.md`](https://github.com/dark5un/ai-lab-quadlets/blob/main/docs/copilot-strata.md)
for the full design and verification trail.

## License

MIT — see the `LICENSE` file in this extension folder (repo root carries the
broader project license).
