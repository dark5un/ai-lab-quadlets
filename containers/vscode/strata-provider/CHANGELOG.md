# Changelog

## 0.2.0

Security and packaging (public-release review, 2026-11-04):

- **Breaking (settings scope):** `strata.baseUrl`, `strata.apiKey` and
  `strata.modelAllowlist` are now **machine-scope** settings. A workspace can
  no longer redirect the auto-attached API key (one "Trust Workspace" click on
  a malicious folder used to be enough to exfiltrate it). Per-box overrides go
  in the server's `data/Machine/settings.json`.
- **Breaking (default):** the public `strata.baseUrl` default is now
  `http://127.0.0.1:8080/v1` (was the ai-lab stack alias).
- **Hardening:** request-core fields (`model`, `messages`, `stream`) are
  re-pinned after spreading `modelOptions`, so caller-supplied options can no
  longer break the SSE transport or target another model; OpenAI-compatible
  extras (`temperature`, `top_p`, `seed`, ...) still pass through verbatim.
- **New setting:** `strata.maxImageBytes` (default 10 MB) — image inputs above
  the cap are skipped with a visible chat notice instead of spiking memory and
  request size every turn.
- Error messages show only `origin + pathname` of the failing URL (no
  userinfo/query echoed into the chat UI).
- Tool-call names survive servers that repeat the full name in every SSE
  delta (previously accumulated to `calculatorcalculator...`).
- Packaged for Marketplace/Open VSX: explicit `activationEvents`, extension
  `LICENSE` (MIT), icon, `files` list, `bugs` URL, CHANGELOG.
- Renamed to **OpenAI-Compatible Local Models (BYOK)**; the vendor id (`strata`)
  and the `strata.*` setting namespace are unchanged, so existing installs keep
  working.

## 0.1.x (ai-lab stack builds)

- Initial provider extension: stable `LanguageModelChatProvider` API, live
  model discovery from `GET {baseUrl}/models` (`meta.n_ctx` → context window,
  `architecture.input_modalities` → vision), full OpenAI tools/tool_calls
  round-trip with streamed argument reassembly, SSE streaming, vision
  passthrough, env-based key (`STRATA_API_KEY`).
