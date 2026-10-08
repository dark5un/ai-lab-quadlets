# Connecting Sketch Lab to Local Models

Sketch Lab has a built-in AI panel that generates diagrams from text prompts.
It talks to any **OpenAI-compatible API** endpoint.

## How it works

1. You describe a diagram in natural language
2. Sketch Lab sends your prompt to an LLM endpoint
3. The LLM returns structured JSON (`GeneratedGraph`)
4. Sketch Lab renders the diagram on the canvas

## Default: same-origin proxy to Strata

The sketchlab image (v0.6.2) ships an nginx that proxies `/v1/` to Strata
(`systemd-strata:8080` on `ai.network`) and injects the Strata API key
server-side from `~/.config/containers/config/sketchlab/service.env`
(`STRATA_API_KEY`, written by `install.sh`). The browser never sees the key,
and there is no CORS to configure: the default endpoint is
`http://<host>:3102/v1` and the model list comes from Strata.

Strata is on-demand. nginx resolves the upstream per request, so Sketch Lab
starts and serves the UI while Strata is off; `/v1/*` then returns `502` until
you start Strata (`ai-lab strata 5090`, or the bar widget).

## Other endpoints

To use a different OpenAI-compatible server, open the AI settings in the
editor and set:

| Setting | Value (example) |
|---|---|
| **Endpoint** | `http://<host-LAN-IP>:11435/v1` (llama-cpp-5090; 11436 = 4070 Ti, 11438 = both cards) |
| **Model** | auto-populated from the endpoint's `/v1/models` |
| **API Key** | the llama.cpp key from `~/.config/containers/config/llama-cpp/keys.txt` |

The browser calls that endpoint directly, so it must be reachable from the
browser and must answer CORS. Only the built-in `/v1` proxy avoids both.

## For AI agents

The sketchlab.app repo ships a zero-dependency stdio MCP server
(`mcp/server.mjs`: `sketchlab_icons`, `sketchlab_validate`,
`sketchlab_diagram`). See its README for the Hermes, Strata and Claude Code
config blocks.

## Required model capabilities

- Follows structured output instructions (system prompt -> JSON)
- Understands graph concepts (nodes, edges, containers)
- At least 8K context (diagrams are verbose as JSON)

Small models (< 8B) often struggle with the full schema.

## Troubleshooting

**Can't reach Sketch Lab in the browser**
- The host publishes `<hostname>.local` via systemd-resolved mDNS. Check with
  `getent hosts "$(hostnamectl --static).local"`.
- Port 3102 must be allowed from your trusted LAN; never port-forward these
  unauthenticated endpoints to the Internet. Anyone who can reach :3102 can
  use the Strata key through the proxy.

**"No models available" / 502 on /v1**
- Strata is off: `ai-lab status`, then start it.
- Check the proxy directly: `curl -s http://127.0.0.1:3102/v1/models`.

**"Empty or invalid diagram"**
- The model may not follow the JSON schema; try a larger model.
