# Connecting Sketch Lab to Local Models

Sketch Lab has a built-in AI panel that generates diagrams from text prompts.
It connects to any **OpenAI-compatible API** endpoint — no special integration needed.

## How it works

1. You describe a diagram in natural language
2. Sketch Lab sends your prompt to a local LLM endpoint
3. The LLM returns structured JSON (`GeneratedGraph`)
4. Sketch Lab renders the diagram on the canvas

## Configuration

### From the host (outside the container network)

Open Sketch Lab at `https://<your-hostname>.local:3004` (the avahi/mDNS name,
e.g. `framework.local`) and click the AI button (magic wand
or brain icon in the editor toolbar). In the settings panel:

| Setting | Value (example) |
|---|---|
| **Endpoint** | `http://127.0.0.1:11435` (llama-cpp-main) |
| **Model** | (auto-populated from endpoint's `/v1/models`) |
| **API Key** | (leave blank for local endpoints without auth) |

### From within the container network

If running Sketch Lab inside the ai.network, you can use the container names
directly:

| Endpoint | Service |
|---|---|
| `http://llama-cpp:8080` | Primary llama.cpp (largest GPU) |
| `http://llama-cpp-research:8080` | Research llama.cpp (2nd GPU) |

### For AI agents (Claude Code, Codex, etc.)

The Sketch Lab skill for AI agents is published at:

**Skill URL:** https://sketchlab.webdevcody.com/skills/sketch-lab/SKILL.md

Install it into Claude Code:

```bash
mkdir -p ~/.claude/skills/sketch-lab
curl -fsSL https://sketchlab.webdevcody.com/skills/sketch-lab/SKILL.md \
    -o ~/.claude/skills/sketch-lab/SKILL.md
```

Then ask: *"Create a flowchart of the user authentication flow in Sketch Lab"*

The agent will generate a `GeneratedGraph` JSON and open it as a `?g=` URL.

## Required model capabilities

For best diagram generation results, the model should:

- Follow structured output instructions (system prompt → JSON)
- Understand graph concepts (nodes, edges, arrows, containers)
- Generate valid JSON with correct `GeneratedGraph` schema
- Handle at least 8K context (diagrams can be verbose as JSON)

Recommended models:
- 27B+ parameter models (e.g., ThinkingCap, Qwen-3.5, Gemma 4)
- Instruction-tuned models with good JSON adherence
- Any model that works well with structured output

## Troubleshooting

**"No models available"**
- Verify the endpoint is running: `curl http://127.0.0.1:11435/v1/models`
- Check the model directory: `ls ~/.local/share/llama.cpp/models/`

**"Connection refused"**
- The service may not be running: `systemctl --user status llama-cpp-main.service`
- From the host, use `127.0.0.1` not container names
- If using container names, make sure both are on `ai.network`

**"Empty or invalid diagram"**
- The model may not support structured output well
- Try a different model or add explicit instructions to the prompt
- Some small models (< 8B) struggle with the full JSON schema