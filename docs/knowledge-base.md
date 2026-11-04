# Knowledge base (KB group)

Plan: `~/tmp/knowledge_base_plan1.md` (v1, 2026-11-04). This doc describes
what is actually deployed and how to operate it.

## What runs

Twelve new units, group `kb` in `services.json`, all on-demand (no
`[Install]`; dormancy per stack convention). Every model call stays on this
box (strata + bge-m3 via ai.network).

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
| n8n | n8nio/n8n 2.46.6 | 127.0.0.1:3115 | W1-W4 analysis workflows |
| kb-analysis | built (kb-watcher image) | none | queue/verdicts/tags/report plumbing |
| kb-watcher | built (same image) | none | nightly one-shot ingest (Type=oneshot) |
| kb-watcher.timer | plain user unit (`services/`) | - | nightly ~03:30+rand, wakes the group via Wants= chain |

Tailnet doors (added 2026-11-04, verified end-to-end from this node):
`tailscale serve --bg --https=8444 -> 127.0.0.1:3114` (RAGFlow),
`:8445 -> 3115` (n8n), `:8446 -> 3116` (LightRAG). Real FQDN never
committed; form: `https://ai.<tailnet>.ts.net:8444` etc. 443 stays dufs,
8443 stays vscode. LightRAG was loopback-unauthenticated by design; before
exposing it we enabled `LIGHTRAG_API_KEY` (generated + mirrored into
kb-watcher/service.env by `scripts/kb-lightrag-auth.py`; clients auth with
the **X-API-Key** header - v1.5.7's Bearer scheme is guest-JWT, not the
api key). RAGFlow + n8n keep their own logins.

Storage: all heavy state in named volumes `kb-es-data kb-mysql-data
kb-minio-data kb-kvrocks-data kb-nats-data kb-lightrag-pg-data
kb-lightrag-data kb-n8n-data kb-ragflow-logs`. Light human-readable state
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
- n8n (SUL) stays loopback-only and client-invisible. The owner account
  (kb-admin@local.ai) was created headlessly via `POST /rest/owner/setup`
  (no CLI owner-create exists; password in `config/n8n/.owner_pw_once`).
  `n8n execute` cannot run beside the live server (task broker port), so
  workflows are triggered through published webhooks
  (`POST http://systemd-n8n:5678/webhook/kb-w1..kb-w4` from in-network,
  127.0.0.1:3115/webhook/... from the host) plus their crons.
- The LLM judging step of W1 runs as n8n HTTP nodes against strata (strict
  JSON + 3 retries); the deterministic side (pair queue, verdict storage,
  RAGFlow tagging, report rendering) is the `kb-analysis` service in the
  watcher image. Plan gate holds: documents are never auto-modified, only
  tagged (`discrepancy`, `gap-adjacent`, `stale-suspect` via meta_fields
  `tags`), and reports carry chunk provenance.
- W4 drift / W2 gaps also render from kb-analysis (`kb/reports/drift.md`,
  `gaps.md`, `stale.md`, `discrepancies.md`).
- Watcher corpus budget: `INGEST_LIMIT=3000` files/run (the scan found
  ~83k files under `~/workspace`); first passes drain the backlog gradually.

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
  crons 05:15/05:30/05:45 run W2/W3/W4. Reports land in `kb/reports/`
  (Syncthing replicates them to your other devices for free - plan D3).
- Backups: named volumes (podman) + `kb/` dir (gitignored, but it is the
  corpus state - include it in volume snapshots).
- Rotating KB secrets: `scripts/rotate-secrets.sh` covers the ragflow env
  (5 keys), kb-postgres/lightrag mirror, n8n key, then restarts the group.

## GCP transfer (plan sec.9, condensed)

All twelve units are standard linux/amd64 containers -> GKE Deployments/
StatefulSets (ES, MySQL, PG, silo) or Cloud Run (LightRAG, n8n stays
self-hosted container, watcher becomes Cloud Run job + Cloud Scheduler,
Pub/Sub from GCS for the corpus). Managed swap-ins: Vertex AI for strata/
bge-m3 slots (re-index on embedding change), Elastic Cloud, Cloud SQL
MySQL/PostgreSQL (pgvector GA - PGTableGraphStorage was chosen exactly for
this), GCS S3-interop for object storage. ADK/Vertex Agent Engine replaces
n8n if the KB ever ships in a client deliverable (never ship the editor).
