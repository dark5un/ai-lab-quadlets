# W3 staleness / update chains (KB plan sec.6) - kb-analysis reuses the W1
# 'updates' relations + file dates; tags stale-suspect, writes the report.
import httpx

def main():
    r = httpx.get("http://systemd-kb-analysis:8090/stale", timeout=600)
    r.raise_for_status()
    return r.json()
