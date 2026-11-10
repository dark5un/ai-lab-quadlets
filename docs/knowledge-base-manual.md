# Knowledge Base Manual — the ai-lab KB platform end to end

Covers every way documents, code and agent artifacts enter the Knowledge
Base, every way to search it, and every pipeline that feeds it. Written
2026-11-10 against the live stack; each component was probed in that
session. (This file is itself ingested into the KB — search "knowledge
base manual" to read it from inside the system it documents.)

## 1. What the platform is

| layer | component | where |
|---|---|---|
| chunk + vector search | RAGFlow (Go v1.x) + Elasticsearch | UI/API http://127.0.0.1:3114 (tailnet door https://ai.<tailnet>.ts.net:8444) |
| knowledge graph | LightRAG 1.5.7 on pgvector | http://127.0.0.1:3116 (door :8446), API key X-API-Key |
| corpus watcher | kb-watcher (nightly 03:30 + manual) | unit `kb-watcher.service`, repo `containers/kb-watcher/` |
| LLM roles | gemma-4-12b on llama-cpp-4070ti (KB), qwen strata (pipelines) | in-stack names `systemd-llama-cpp-4070ti`, `systemd-strata` |
| embeddings | bge-m3 on `systemd-embeddings:8080` (CPU) | fixed 1024-dim since first index — DO NOT change without recreating storage |
| pipeline group | Concourse 8.3.3 + Garage S3 + Forgejo | :3122/:3121/:3120 |
| agentic flows | Windmill (W1–W4) + Concourse pipelines | repo `windmill/`, `pipelines/` |

Databases are NAMED podman volumes (`kb-es-data`, `kb-lightrag-pg-data`, …).
The corpus is exactly `~/KB` (CORPUS_ROOT); light KB state (manifest,
reports) lives in this repo's `kb/` folder (gitignored).

Bring the whole group up:

    systemctl --user start embeddings.service llama-cpp-4070ti.service \
      ragflow-elasticsearch.service ragflow-mysql.service ragflow-nats.service \
      ragflow-minio.service ragflow-kvrocks.service kb-postgres.service
    systemctl --user start ragflow.service lightrag.service

Health: `curl :3116/health` (LightRAG JSON), `curl :3114/api/v1/datasets`
with Bearer key (RAGFlow), `curl :11436/health` (4070ti LLM). Keys:
`~/.config/containers/config/kb-watcher/service.env`.

## 2. Getting things INTO the KB

### 2.1 Corpus watcher (human files)
Drop files under `~/KB/` (any depth; dot-dirs, node_modules, .venv, .git
are skipped; `.kbignore` per dir). Allowed: pdf/docx/xlsx/pptx/eml/png/jpg,
md/txt, and code (.py .go .ts .js .java .c .cpp .h .sh .yml .json .html).
Dataset routing: documents→`docs-general`, notes→`docs-notes`,
code→`docs-code`. The nightly `kb-watcher.timer` diffs by sha256 and only
re-ingests changes; run on demand: `systemctl --user start kb-watcher.service`
(blocks until done; pass budgets via INGEST_LIMIT). Each pass writes a
report under `kb/reports/`.

### 2.2 Shared ingest client
`pipeline-lab` repo (`agents/kb_ingest.py` on Forgejo, mirrored at
`~/KB/tools/pipeline-agents/`) is THE client every producer uses:
upload→parse→wait into RAGFlow, delete-by-source then insert into LightRAG
(the 409 dedup keys on file_source basename). Replace-semantics per name:
re-ingesting a same-named file updates, never duplicates. CLI:

    python3 agents/kb_ingest.py file <path> [dataset]
    python3 agents/kb_ingest.py text <name> <file.md> [dataset]
    python3 agents/kb_ingest.py search <query> [dataset]

### 2.3 Concourse pipelines (agentic producers)
All pipelines live in this repo's `pipelines/`, applied with
`config/concourse/pipeline-vars.yml` (0600, never in git):

* **docs-agent** — any doc uploaded to `s3://doc-inbox/pending/<epoch>-name.md`
  → strata summary → `s3://doc-summaries/summaries/` → AND the summary is
  mirrored into the KB dataset `agent-output` (KB integration, 2026-11-10).
* **repo-review** — push to `review/next` of pilot-cli → gates + prowl +
  strata review → PR comment → AND review notes + changed sources are
  mirrored into `agent-output` / `docs-code`.
* **kb-papers** — `fetch-papers` job (manual; arXiv scout): PDFs →
  `s3://doc-inbox/papers/`, paper cards → `pending/`; `kb-ingest-papers`
  job (event-driven): PDFs → KB dataset `ai-papers` + graph mirror, ledger
  `s3://ci-artifacts/papers/kb-ingested.json`, originals archived to
  `papers-processed/`.
* **night-kitchen** — the relay scenario, section 5.

Vars the pipeline tasks use for the KB: `kb-ragflow-key`, `kb-lightrag-key`
in pipeline-vars.yml (added by the 2026-11-10 integration).

## 3. Searching the KB

### 3.1 CLI clients (`tools/kbsearch/` in this repo — also indexed in the KB)
Go: `./kbsearch [-d dataset] [-n N] [-graph] <query>`
Python: `python3 kbq.py [-d DATASET] [-n N] [--graph] <query>`
Both stdlib-only; env: RAGFLOW_URL + RAGFLOW_API_KEY (+ LIGHTRAG_*).
From the host use `RAGFLOW_URL=http://127.0.0.1:3114`.
RAGFlow retrieval REQUIRES explicit dataset_ids (code 101 otherwise) — the
clients default to all datasets.

### 3.2 Web UIs
RAGFlow (chat assistants, datasets, chunk preview): :3114 / door :8444.
LightRAG (graph visualization + query): :3116 / door :8446.

### 3.3 Datasets at a glance (2026-11-10)
`docs-general` (corpus documents + papers), `docs-notes`, `docs-code`,
`agent-output` (pipeline summaries/reviews/kitchen notes),
`ai-papers` (kb-papers pipeline PDFs).

## 4. S3 folders over WebDAV

Service `s3-webdav` (unit, quadlet `quadlets/s3-webdav.container`, added
2026-11-10): rclone serve webdav over the Garage S3 endpoint, exposing
EVERY bucket as a top-level folder — `doc-inbox/`, `doc-summaries/`,
`ci-artifacts/` (pipeline artifacts incl. `nk/`, `papers/`, `images/`).

* URL (tailnet-only, same posture as the dufs home share):
  `https://ai.<tailnet>.ts.net:8449/` — loopback origin `127.0.0.1:3124`.
* Login: user `webdav`, password plaintext mirror + apr1 hash in
  `~/.config/containers/config/s3-webdav/service.env` / `htpasswd`
  (generated by `scripts/generate-secrets.sh`; rclone accepts apr1 via
  `openssl passwd -1` — sha-512-crypt does NOT work with it).
* Finder: ⌘K → `https://ai.<tailnet>.ts.net:8449/`.
* SigV4 region MUST be `garage` (RCLONE_CONFIG_GARAGE_REGION) — the default
  us-east-1 scope is rejected by Garage (verified live).
* The webdav account writes with the SAME Garage key the pipelines use
  (`s3/service.env` mirror) — deletions over WebDAV are real deletions.

## 5. The Night Kitchen (scenario pipeline)

`pipelines/night-kitchen.yml` + `agents/nk_*.py` in pipeline-lab. Five
personas hand off through `s3://ci-artifacts/nk/` (epoch-key resources):

scout → `nk/papers/` (1 arXiv card; also feeds docs-agent) →
distiller → `nk/design/` (mechanism JSON) →
taster → critic scores ≥7 gate; winner `nk/winner/`, every note → KB →
cook → writes prototype (Go/Python, stdlib, gate-checked) into repo
`pipeline/night-kitchen` branch `review/next` →
serve → the repo-review agent reviews it, opens a PR, mirrors review +
sources into KB →
wash-up → kitchen log `nk/log/<date>-kitchen-log.md` + fed back into
doc-inbox for another summarization round.

Run a night by hand:

    fly -t local trigger-job -j night-kitchen/scout
    # each later stage fires itself off its resource; watch with:
    fly -t local watch -j night-kitchen/<job> -b <n>

Idempotency ledgers: `nk/distilled.json`, `nk/tasted.json`,
`nk/cooked.json`. The scout also runs on the `twice-daily` time resource.
All personas' output is searchable: query the KB for
"Night Kitchen design card" or `-graph "Night Kitchen personas"`.

## 6. VS Code environments on Kubernetes (feasibility — VERDICT + live POC)

Full plan with verification appendix: `docs/vscode-k8s-plan.md`. Verified
2026-11-10 by a live POC: **kind v0.33.0 with the rootless-Podman provider
(`KIND_EXPERIMENTAL_PROVIDER=podman`) works on this box with zero host
changes.** POC: cluster `vscode-poc`, k8s v1.37.0, two namespaces
(`env-alice`/`env-bob`) each serving `codercom/code-server:4.145.2` behind
per-env token Secrets on loopback NodePorts; cross-env token rejection and
full cluster teardown (no leftover containers/volumes/ports) proven live.
Notes: `code-server:lts` tag does NOT exist — pin numeric tags; GPU-into-
kind via CDI is UNVERIFIED (rootful-docker demos only) — GPU VS Code stays
on the quadlet `vscode` path; k3d v5.9.0 is the fallback option; `podman
play kube` rejected (not Kubernetes). Cleanup automation: draft Concourse
pipeline with manual `create-env`/`destroy-env`/`renew-env` jobs plus a
time-triggered `expire-idle-envs` job (TTL annotation) — sketch in the plan
doc; deliberately NOT set live until the owner adopts it.

## 7. Operations

* `ailab-access` (~/.local/bin): live table of every quadlet service —
  access URL, tailscale door + port, host port, username and password/key
  for the ones that have them. Output contains real secrets — keep it on-box.
* RAGFlow rc3 runs ONE ingestion worker: big batches drain slowly
  (documents sit `SCHEDULED` while queued — that is queueing, not failure;
  the client-side PARSE_TIMEOUT in kb_ingest/watcher measures patience,
  not RAGFlow health). Re-check status later rather than re-uploading.
* kb_ingest replace-semantics key on the EXACT uploaded name — artifacts
  must be named deterministically (`name.md`, never a random tmp prefix).
* Under a failed watcher parse-timeout the file IS in the manifest but its
  LightRAG mirror was skipped — catch up via chunk-fetch mirror (see the
  mirror_papers pattern) once the queue drains.
* Secrets: `scripts/generate-secrets.sh` (keeps existing; `--force`
  replaces) covers the KB group + s3-webdav; `scripts/rotate-secrets.sh`
  rotates. Tests: `scripts/run-tests.sh`.
* Reasoning-model guard for KB LLM roles: `reasoning_effort:'none'` on
  JSON-extraction calls (LightRAG env `{ROLE}_OPENAI_LLM_REASONING_EFFORT`);
  embeddings server needs `LLAMA_ARG_UBATCH=2048` for >512-token chunks.
* LightRAG mirror lifecycle: delete-by-source before insert; failed docs via
  `POST /documents/reprocess_failed`; graph API is `GET /graphs`.
* Never run dataset orphan-cleanup while a watcher pass is in-flight.
* Changing the embedding model = recreating all vector storage (frozen).

## 8. Index of code written for this integration

| artifact | location |
|---|---|
| KB ingest client (shared) | pipeline-lab `agents/kb_ingest.py` |
| doc summarizer + KB mirror | pipeline-lab `agents/summarize_docs.py` |
| code reviewer + KB mirror | pipeline-lab `agents/review_change.py` |
| arXiv fetch + KB paper ingest | pipeline-lab `agents/fetch_papers.py`, `agents/ingest_papers.py` |
| Night Kitchen personas | pipeline-lab `agents/nk_common.py`, `nk_distill.py`, `nk_taste.py`, `nk_cook.py`, `nk_washup.py` |
| Go + Python search clients | this repo `tools/kbsearch/` (main.go, kbq.py) |
| WebDAV front | this repo `quadlets/s3-webdav.container`, `config/s3-webdav/` |
| pipeline YAMLs | this repo `pipelines/{docs-agent,repo-review,kb-papers,night-kitchen}.yml` |

Every row above is searchable in the KB itself (docs-code + agent-output).
