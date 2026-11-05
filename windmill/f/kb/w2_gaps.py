# W2 gap detection (KB plan sec.6) - single call: kb-analysis runs the
# LightRAG entity inventory + RAGFlow coverage probes and writes
# kb/reports/gaps.md + gap-adjacent tags.
import httpx

def main():
    r = httpx.get("http://systemd-kb-analysis:8090/coverage", timeout=600)
    r.raise_for_status()
    return r.json()
