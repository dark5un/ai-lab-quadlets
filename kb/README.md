# kb/ - knowledge-base project state (light, human-managed)

Everything here except this README is gitignored and must stay that way:
the content is derived from the private corpus (~/KB),
and this repo is public. Heavy per-service state lives in named podman
volumes (kb-es-data, kb-mysql-data, kb-minio-data, kb-kvrocks-data,
kb-nats-data, kb-lightrag-pg-data, kb-ragflow-logs,
kb-lightrag-data), not in this tree.

Layout (plan: ~/tmp/knowledge_base_plan1.md):

- `manifest.json`        corpus-watcher sha256 manifest + last-run summary
- `watcher-errors.json`  per-doc ingestion failures (retry <= 3 then recorded)
- `reports/`             nightly ingest digests + discrepancies.md, gaps.md
- `state/`               analysis SQLite (pair queue, verdicts) for W1-W4
- `fixtures/`            seeded acceptance docs (P1/P4/P5 criteria)

All paths are also the container-side paths: the kb-watcher quadlet mounts
this directory at the identical host path read-write, and the corpus roots
read-only at their host paths (same-path rule).
