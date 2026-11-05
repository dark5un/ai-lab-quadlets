# W1 discrepancy detection (KB plan sec.6) - Windmill port of the n8n W1
# workflow (owner directive 2026-11-05: n8n -> Windmill).
# Queue: systemd-kb-analysis /pairs -> gemma router classify (strict JSON,
# reasoning off) -> /record (kb-analysis applies tags + discrepancies.md).
# Never auto-modifies documents; every report row carries provenance.
import httpx
from wmill import get_variable

AN = "http://systemd-kb-analysis:8090"
LLM = "http://systemd-llama-cpp-4070ti:8080/v1"
MODEL = "gemma-4-12b-it-qat-q4_0"
ALLOWED = ["contradicts", "updates", "supports", "redundant", "unrelated"]

PROMPT = (
    "You are a factual-consistency checker for a personal knowledge base. "
    "Below are two documents (A and B). Extract the key factual claims from each, "
    "then classify their relation as exactly one of: contradicts, updates, supports, "
    "redundant, unrelated. Rules: 'updates' means B supersedes A (newer state of the "
    "same fact); 'contradicts' means mutually exclusive claims about the same subject. "
    "Reply with STRICT JSON: {\"relation\":\"...\",\"confidence\":0.0,\"topic\":"
    "\"short-slug\",\"claims\":{\"a\":\"claim from A\",\"b\":\"claim from B\"},"
    "\"provenance\":{\"a_chunk\":true,\"b_chunk\":true}}.\n\n"
)


def classify(client: httpx.Client, key: str, pair: dict) -> dict:
    prompt = (
        PROMPT
        + f"\n=== DOC A (pair {pair['pair_id']}) ===\n{pair['text_a']}"
        + f"\n\n=== DOC B ===\n{pair['text_b']}"
    )
    last_err = None
    for _ in range(3):  # retry policy = 3 (inherited from the old n8n flow)
        try:
            r = client.post(
                f"{LLM}/chat/completions",
                headers={"Authorization": f"Bearer {key}"},
                json={
                    "model": MODEL,
                    "temperature": 0,
                    "max_tokens": 900,
                    "reasoning_effort": "none",
                    "response_format": {"type": "json_object"},
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=240,
            )
            r.raise_for_status()
            import json

            try:
                v = json.loads(r.json()["choices"][0]["message"]["content"])
            except Exception:
                v = {"relation": "unrelated", "confidence": 0,
                     "topic": "parse-error", "claims": {}, "provenance": {}}
            if v.get("relation") not in ALLOWED:
                v["relation"] = "unrelated"
            return {
                "pair_id": pair["pair_id"],
                "relation": v["relation"],
                "confidence": v.get("confidence") or 0,
                "topic": v.get("topic") or "pair",
                "claims": v.get("claims") or {},
                "provenance": v.get("provenance") or {},
            }
        except Exception as e:  # transport error: retry
            last_err = str(e)[:200]
    return {"pair_id": pair["pair_id"], "relation": "unrelated",
            "confidence": 0, "topic": "llm-error", "claims": {},
            "provenance": {}, "_error": last_err}


def main(budget: int = 100):
    key = get_variable("f/kb/router_key")
    out = {"processed": 0, "contradicts": 0, "errors": 0}
    with httpx.Client() as client:
        r = client.get(f"{AN}/pairs", params={"budget": budget}, timeout=120)
        r.raise_for_status()
        pairs = [p for p in r.json().get("pairs", []) if p.get("text_a") and p.get("text_b")]
        for pair in pairs:
            verdict = classify(client, key, pair)
            if verdict.pop("_error", None):
                out["errors"] += 1
            rr = client.post(f"{AN}/record", json=verdict, timeout=60)
            rr.raise_for_status()
            out["processed"] += 1
            if verdict["relation"] == "contradicts":
                out["contradicts"] += 1
    return out
