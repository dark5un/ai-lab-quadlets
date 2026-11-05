# Knowledge base (KB group)

Plan: `~/tmp/knowledge_base_plan1.md` (v1, 2026-11-04). This doc describes
what is actually deployed and how to operate it.

## What runs

Twelve units, group `kb` in `services.json`, all on-demand (no
`[Install]`; dormancy per stack convention) — n8n was the thirteenth until
the 2026-11-05 teardown (P1.4, windmill-jupyter plan). Every model call
stays on this box.

| unit | image | host port | role |
|---|---|---|---|
| ragflow | infiniflow/ragflow v1.0.0-rc3 (Go line) | 127.0.0.1:3114 UI | ingestion, DeepDoc parse, hybrid retrieval, chat |
| ragflow-elasticsearch | elasticsearch 8.11.3 | none | doc engine |
| ragflow-mysql | mysql 8.0.40 | none | metadata |
| ragflow-minio | pgsty/silo (MinIO-compatible) | none | object storage |
| ragflow-kvrocks | apache/kvrocks 2.16.0 | none | cache/RunTracker (Go line) |
| ragflow-nats | nats 2.14.2 JetStream | none | ingestion queue |
| kb-postgres | pgvector/pgvector pg18 | none | LightRAG storage |
| lightrag | hkuds/lightrag v1.5.7 | 127.0.0.1:3116 | exportable knowledge graph |
| windmill-* (automation group) | windmill-labs/windmill 1.862.0 + pg18 | 127.0.0.1:3117 | W1-W4 analysis scripts/schedules (P1 since 2026-11-05; replaced n8n, which is deleted) |
| kb-analysis | built (kb-watcher image) | none | queue/verdicts/tags/report plumbing |
| kb-watcher | built (same image) | none | nightly one-shot ingest (Type=oneshot) |
| kb-watcher.timer | plain user unit (`services/`) | - | nightly ~03:30+rand, wakes the group via Wants= chain |

Tailnet doors (added 2026-11-04, verified end-to-end from this node):
`tailscale serve --bg --https=8444 -> 127.0.0.1:3114` (RAGFlow),
`:8446 -> 3116` (LightRAG). (An `:8445 -> 3115` n8n door existed until the
2026-11-05 teardown; removed via `tailscale serve --https=8445 off`.)
Real FQDN never
committed; form: `https://ai.<tailnet>.ts.net:8444` etc. 443 stays dufs,
8443 stays vscode. LightRAG was loopback-unauthenticated by design; before
exposing it we enabled `LIGHTRAG_API_KEY` (generated + mirrored into
kb-watcher/service.env by `scripts/kb-lightrag-auth.py`; clients auth with
the **X-API-Key** header - v1.5.7's Bearer scheme is guest-JWT, not the
api key). RAGFlow keeps its own login.

Storage: all heavy state in named volumes `kb-es-data kb-mysql-data
kb-minio-data kb-kvrocks-data kb-nats-data kb-lightrag-pg-data
kb-lightrag-data kb-ragflow-logs` (the former kb-n8n-data volume was
backed up to ~/.local/share/ai-lab-backups/ and deleted 2026-11-05). Light human-readable state
in this repo under `kb/` (gitignored - public repo, corpus-derived).

## Deviations from the plan (verified live at install)

- **D1 boot posture**: on-demand only, as defaulted. The nightly timer is the
  activator.
- **D2 release pin**: RAGFlow v1.0.0-rc3 (the "final RC before v1.0.0" of the
  adopted Go line). Rollback path kept: v0.27.3 python-line images share the
  MySQL/ES/MinIO data formats.
- Object storage is `pgsty/silo`, not minio/minio (that is what the rc3
  compose ships; same MINIO_ROOT_* contract). Cache is `apache/kvrocks:2.16.0`
  with the upstream config-rendering entrypoint (copied to
  `config/ragflow/kvrocks-entrypoint.sh`, Apache-2.0).
- podman 6.1 quadlets have no native `[Timer]` section: scheduling uses a
  plain user timer (`services/kb-watcher.timer`, install.sh enables it)
  activating the quadlet-generated `kb-watcher.service`.
- n8n (SUL) stayed loopback-only and client-invisible until the 2026-11-05
  teardown (kept as a quirks record, it informed the Windmill wiring): the
  owner account was created headlessly via `POST /rest/owner/setup` (no CLI
  owner-create exists); `n8n execute` cannot run beside the live server
  (task broker port), so workflows ran through published webhooks plus
  their crons; generic HTTP nodes strip plaintext Authorization headers
  (httpHeaderAuth credential required, and one-shot-POSTed credentials fail
  at runtime — "Credentials not found").
- The LLM judging step of W1 runs in **Windmill** (owner decision
  2026-11-05: n8n -> Windmill; n8n fully deleted 2026-11-05 after green
  Windmill runs — plan P1.4). Scripts f/kb/w1_discrepancy..w4_drift call the llama-cpp-4070ti
  router (strict JSON + 3 retries; router key as Windmill secret variable
  f/kb/router_key kept in sync by scripts/windmill-vars.py) and the
  deterministic side (pair queue, verdict storage, RAGFlow tagging, report
  rendering) is the `kb-analysis` service in the watcher image. Plan gate
  holds: documents are never auto-modified, only tagged (`discrepancy`,
  `gap-adjacent`, `stale-suspect` via meta_fields `tags`), and reports carry
  chunk provenance. P4 + P5 acceptance VERIFIED 2026-11-05 on Windmill
  (widget-assembly contradiction pair: both docs tagged, discrepancies.md
  rows; gaps.md ranks zorblatt single-source entities).
  Watcher completion hook: `WM_WEBHOOK_URL` (+`?token=`) ->
  `POST http://systemd-windmill-server:8000/api/w/kb/jobs/run/p/...`;
  fallback crons are Windmill schedules (6-field crontab, seconds first)
  materialized as windmill/f/kb/*.schedule.yaml via wmill sync.
- W4 drift / W2 gaps also render from kb-analysis (`kb/reports/drift.md`,
  `gaps.md`, `stale.md`, `discrepancies.md`).
- Corpus scope (owner directive 2026-11-05): only the dedicated folder in
  `CORPUS_ROOT` is corpus - `~/KB` for now (configurable env + quadlet mount,
  so it can move to a permanent location later). No pre-existing server files
  (`~/workspace`, `~/Documents`) are scanned; the earlier ~83k-file backlog
  decision was retired and all previously-ingested server files are
  tombstoned. RAGFlow v1.0-rc3 cannot ingest `.rs/.cc/.hpp/.yaml/.toml`
  uploads ("type not supported") - the watcher allowlist matches exactly
  what RAGFlow accepts (live-probed 2026-11-05).

## Model wiring (live 2026-11-05)

KB LLM roles (RAGFlow chat/assist, LightRAG extract/keyword/query, Windmill W1
classify, watcher classify) run on the **llama-cpp-4070ti router** with the
official **Gemma 4 12B-it QAT q4_0** (`google/gemma-4-12B-it-qat-q4_0-gguf`,
Apache-2.0, router model id = card subdir `gemma-4-12b-it-qat-q4_0`,
ctx 262144 via refresh-presets.py — the script now understands gemma4's
per-layer hybrid attention arrays). Owner directive 2026-11-05: KB must not
occupy strata. Embeddings stay bge-m3/systemd-embeddings (1024d frozen).
Auth: shared llama.cpp key (config/llama-cpp/keys.txt), mirrored into
lightrag + kb-watcher envs by generate-secrets.sh and kept current by
install.sh managed lines. Note: starting llama-cpp-4070ti takes the card
from strata-coder (arbiter rule).

## RAGFlow 1.0 API quirks (all verified live; codified in
## `containers/kb-watcher/watcher.py` and `scripts/kb-bootstrap.sh`)

- parse = `POST /api/v1/datasets/{id}/chunks`, not `/documents/parse`
- dataset create uses `{"parse_type":1,"parser_id":"general"}`, not
  `chunk_method`
- list-documents returns `data.docs` (dict), upload returns `data` (list)
- datasets list rejects `limit` (use `page_size`)
- the `ragflow_auth` login cookie value doubles as `Authorization: Bearer`
  for session endpoints (e.g. `POST /api/v1/system/tokens` -> PAT)
- superuser admin@ragflow.io cannot console-login (Admin-service only);
  use a regular bot user (kb-bot@local.ai; password
  `config/ragflow/.kbuser_pw_once`)
- OpenAI-compatible chat completion requires
  `"model": "<name>@<instance>@<provider>"` in the body
- LightRAG has no custom doc ids: join by `file_source`
  (`POST /documents/paginated`, delete via `DELETE /documents/delete_document`)
- RAGFlow Go line documents report `ingestion_status` ("COMPLETED"/...),
  not the legacy numeric `run` field — the watcher polls both (fixed
  2026-11-04; false parse-TIMEOUT errors before that)
- LightRAG mirror inserts are rejected (409 "already contains ... Status:
  analyzing") while a same-`file_path` doc exists in any state — watcher now
  always `lr_delete_by_source` before insert (fixed 2026-11-04)
- strata is a thinking model: with thinking ON one LightRAG extraction call
  burns >12k hidden-reasoning tokens, hits `finish=length` (truncated JSON)
  and blows LightRAG's worker timeout (`2*LLM_TIMEOUT`, default 480 s) — all
  mirrored docs failed. Verified live: same call with `reasoning_effort=none`
  → ~22 s, `finish=stop`, clean merge (140 entities). Config fix in
  `config/lightrag/service.env.example` + live:
  `EXTRACT/KEYWORD/QUERY_OPENAI_LLM_REASONING_EFFORT=none`, `LLM_TIMEOUT=600`
  (role env pattern `{ROLE}_OPENAI_LLM_{FIELD}` verified against v1.5.7
  `binding_options.options_dict_for_role`; startup log confirms
  `extract: OpenAI {'reasoning_effort': 'none'}`). Failed docs recover via
  `POST /documents/reprocess_failed`.
- bge-m3 llama.cpp server rejects embedding inputs over its physical batch
  size (512 default): `500 input (1212 tokens) is too large to process` —
  LightRAG's 1200-token chunks therefore failed every PGVector flush
  (verified live 2026-11-04). Root fix in `quadlets/embeddings.container`:
  `LLAMA_ARG_UBATCH=2048` (pure-CPU server, 8192 ctx; benefits every embed
  consumer, not just the KB). Deliberate deviation from plan §13 "do not
  change the embeddings unit": a capacity flag, not a model/wiring change.
- `ADMIN_DEFAULT_PASSWORD` init mismatch: reset the scrypt hash directly in
  MySQL (werkzeug format, see git log 2026-11-04)

## Operations

- Start the whole group: `systemctl --user start kb-watcher.service`
  (Wants= chain wakes ragflow deps + lightrag + embeddings; strata is
  boot-tier) or start pieces via `ai-lab start ragflow`.
- Re-bootstrap models/datasets/PAT: `scripts/kb-bootstrap.sh`
- Nightly: 03:30 timer -> watcher pass -> completion webhook -> W1 ->
  W2/W3/W4; Windmill fallback schedules (6-field cron, UTC): W1 04:30,
  W2 05:30, W3 05:45, W4 06:00. Reports land in `kb/reports/`
  (Syncthing replicates them to your other devices for free - plan D3).
- Backups: named volumes (podman) + `kb/` dir (gitignored, but it is the
  corpus state - include it in volume snapshots).
- Rotating KB secrets: `scripts/rotate-secrets.sh` covers the ragflow env
  (5 keys) and the kb-postgres/lightrag mirror, then restarts the group.

## GCP transfer (plan sec.9, condensed)

All twelve units are standard linux/amd64 containers -> GKE Deployments/
StatefulSets (ES, MySQL, PG, silo) or Cloud Run (LightRAG, Windmill stays
self-hosted container, watcher becomes Cloud Run job + Cloud Scheduler,
Pub/Sub from GCS for the corpus). Managed swap-ins: Vertex AI for strata/
bge-m3 slots (re-index on embedding change), Elastic Cloud, Cloud SQL
MySQL/PostgreSQL (pgvector GA - PGTableGraphStorage was chosen exactly for
this), GCS S3-interop for object storage. ADK/Vertex Agent Engine replaces
Windmill if the KB ever ships in a client deliverable (never ship the
editor).
