#!/usr/bin/env python3
"""kbq — a small Knowledge-Base search client (Python twin of tools/kbsearch).

Queries RAGFlow retrieval (vector+keyword chunks) and optionally the LightRAG
knowledge graph, printing ranked results to stdout. Stdlib-only.

Usage:
  kbq.py [-d DATASET] [-n N] [--graph] QUERY...

Env:
  RAGFLOW_URL (default http://systemd-ragflow:9380), RAGFLOW_API_KEY (required)
  LIGHTRAG_URL (default http://systemd-lightrag:9621), LIGHTRAG_API_KEY (optional)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

RAGFLOW_URL = os.environ.get("RAGFLOW_URL", "http://systemd-ragflow:9380").rstrip("/")
LIGHTRAG_URL = os.environ.get("LIGHTRAG_URL", "http://systemd-lightrag:9621").rstrip("/")


def _post(url: str, body: dict, headers: dict) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **headers}, method="POST")
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read().decode())


def _get(url: str, headers: dict) -> dict:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def rf_headers() -> dict:
    key = os.environ.get("RAGFLOW_API_KEY", "")
    if not key:
        sys.exit("FATAL: RAGFLOW_API_KEY not set (value never logged)")
    return {"Authorization": "Bearer " + key}


def dataset_ids() -> dict[str, str]:
    d = _get(f"{RAGFLOW_URL}/api/v1/datasets?page=1&page_size=100", rf_headers())
    return {x["name"]: x["id"] for x in d.get("data", [])}


def search(query: str, dataset: str | None, top: int) -> None:
    body: dict = {"question": query, "page_size": top}
    # RAGFlow v1 retrieval needs explicit dataset_ids; default = all datasets
    ids = dataset_ids()
    if dataset:
        if dataset not in ids:
            sys.exit(f"unknown dataset {dataset!r}; have: {', '.join(sorted(ids))}")
        body["dataset_ids"] = [ids[dataset]]
    else:
        body["dataset_ids"] = list(ids.values())
    r = _post(f"{RAGFLOW_URL}/api/v1/retrieval", body, rf_headers())
    data = r.get("data") or {}
    chunks = data.get("chunks") or []
    print(f"== RAGFlow: {data.get('total', len(chunks))} match(es), showing {len(chunks)} ==")
    for i, c in enumerate(chunks, 1):
        snippet = " ".join(c.get("content", "").split())[:240]
        print(f"{i:2d}. [{c.get('document_keyword', '?')}] (sim {c.get('similarity', 0):.3f})\n    {snippet}")


def graph(query: str) -> None:
    headers = {}
    if k := os.environ.get("LIGHTRAG_API_KEY"):
        headers["X-API-Key"] = k
    r = _post(f"{LIGHTRAG_URL}/query", {"query": query, "mode": "hybrid"}, headers)
    print("== LightRAG (knowledge graph, hybrid) ==")
    print((r.get("response") or "").strip())


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description="KB search client")
    ap.add_argument("-d", "--dataset", help="restrict to one RAGFlow dataset")
    ap.add_argument("-n", "--top", type=int, default=8)
    ap.add_argument("--graph", action="store_true", help="query LightRAG instead")
    ap.add_argument("query", nargs="+")
    a = ap.parse_args()
    q = " ".join(a.query)
    if a.graph:
        graph(q)
    else:
        search(q, a.dataset, a.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
