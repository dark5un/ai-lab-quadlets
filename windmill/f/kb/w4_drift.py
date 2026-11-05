# W4 corpus drift (KB plan sec.6) - per-repo doc count/size deltas from the
# watcher manifest -> digest section of the nightly report.
import httpx

def main():
    r = httpx.get("http://systemd-kb-analysis:8090/drift", timeout=300)
    r.raise_for_status()
    return r.json()
