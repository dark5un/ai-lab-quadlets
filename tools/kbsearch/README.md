# kbsearch — Knowledge Base search clients

Two small clients for the ai-lab Knowledge Base (RAGFlow retrieval +
LightRAG knowledge graph). They are the reference "how do I query the KB"
programs; both source files are themselves indexed in the KB (docs-code
dataset) — search for `kbsearch` or `kbq` inside the KB to find them.

## Go client (`kbsearch`)

    go build -o kbsearch .        # go.mod is stdlib-only
    RAGFLOW_URL=http://127.0.0.1:3114 RAGFLOW_API_KEY=... ./kbsearch "agentic pipelines"
    ./kbsearch -d ai-papers -n 5 retrieval augmented
    ./kbsearch -graph "what entities connect RAGFlow and LightRAG"

Env: RAGFLOW_URL (in-stack default http://systemd-ragflow:9380; host loopback
http://127.0.0.1:3114), RAGFLOW_API_KEY (required), LIGHTRAG_URL,
LIGHTRAG_API_KEY. Keys live in
~/.config/containers/config/kb-watcher/service.env (RAGFLOW_API_KEY,
LIGHTRAG_API_KEY) — never in this repo.

## Python client (`kbq.py`)

    python3 kbq.py "agentic pipelines"
    python3 kbq.py -d docs-code --top 3 watcher manifest
    python3 kbq.py --graph "Night Kitchen personas"

Same env contract. Stdlib-only (urllib).

## API notes (verified live)

* RAGFlow 1.0 retrieval is POST /api/v1/retrieval and REQUIRES explicit
  `dataset_ids` (error code 101 otherwise); no dataset flag = all datasets.
* LightRAG auth is the X-API-Key header (Bearer is its guest-JWT only).
* Graph queries answer through the KB LLM (gemma on llama-cpp-4070ti) —
  give -graph calls up to a couple minutes.
