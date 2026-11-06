# Notebook platform (deployed reality, 2026-11-05)

Plan: `~/tmp/windmill-jupyter-plan1.md` (P2). One shared server on the ai
box; owners = Panos + agents; team growth path deferred (plan P3).

## Shape

| piece | value |
|---|---|
| unit | `notebook.service` (group `automation`, dormant) |
| image | built: `containers/notebook/Containerfile` = quay.io/jupyter/scipy-notebook:lab-4.6.4 + `marimo>=0.25` + `marimo-jupyter-extension` + openai (base tag+digest verified live 2026-11-05) |
| port | 127.0.0.1:3118 -> 8888; tailnet door LIVE: svc:notebook -> https://notebook.<tailnet>.ts.net (tailscale serve --service=svc:notebook --https=443 http://127.0.0.1:3118; verified HTTPS 200; hit tailscale#18821 at setup - clear+re-advertise remedy, see docs/windmill.md) |
| auth | token FILE config/notebook/jupyter-token (600, generate-secrets owns it; rotate regenerates) pinned via config/notebook/jupyter_server_config.py - docker-stacks' start-notebook.py MINTS ITS OWN token and shadows --ServerApp.token_file (verified live) |
| notebooks | `~/workspace/notebooks` - OWN git repo, mounted at the SAME host path (agents edit files directly; Syncthing replicates ~/workspace for free) |
| state | named volume `notebook-state` (jupyter config/runtime under /home/jovyan/.jupyter) |
| kernels | CPU-light by owner decision: no GPU fields, no AddDevice; CUDA experiments belong on the dev boxes |

## Integration facts (verified)

- The marimo-in-JupyterLab package is `marimo-jupyter-extension` (replaces
  jupyter-marimo-proxy; the old `marimo[jupyterlab]` extra does not exist on
  current marimo - PyPI extras are lsp/mcp/otel/recommended/sandbox/sql).
  It rides jupyter-server-proxy, so marimo sessions are served on the SAME
  8888 origin - one door, one token story.
- marimo notebooks are plain Python: `*_mo.py` opens in marimo by default;
  `.ipynb` right-click -> "Convert to marimo" (interop both ways via
  `marimo convert` / `marimo export ipynb`).
- VS Code boxes: kernel picker -> "Existing Jupyter Server" ->
  `http://systemd-notebook:8888/?token=<token>` from inside ai.network, or
  the loopback/door URL otherwise. Single source of truth for kernels.
- Platform connection for every kernel: env file `config/notebook/service.env`
  (KB_ROUTER_URL/KEY, RAGFLOW_URL/API_KEY, LIGHTRAG_URL/API_KEY, WM_URL/
  WM_AGENT_TOKEN) - install.sh mirrors the key COPIES from the owning
  services' secrets (llama-cpp keys.txt, kb-watcher env, windmill
  agent-token); helper `platform_.py` in the notebooks repo wraps them.

## Gates (all verified live 2026-11-05; re-run after any redeploy)

1. `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3118/api/status` -> 403 (=alive, token-gated)
2. with `?token=<content of jupyter-token>` -> 200.
3. marimo round-trip: demo.ipynb -> `podman exec systemd-notebook marimo
   convert ... -o demo_mo.py` -> `python demo_mo.py` headless -> both live
   in the notebooks git repo (same-path mount).
4. `jupyter labextension list` shows @marimo-team/jupyter-extension enabled;
   `jupyter server extension list` shows marimo_jupyter_extension.handlers +
   jupyter_server_proxy enabled.
5. platform env: 8 KB_ROUTER/RAGFLOW/LIGHTRAG/WM vars in the container;
   platform_.py helpers return live values.
6. VS Code attach from a box + run one cell (user-side check).
