#!/usr/bin/env python3
"""s3-probe.py — minimal SigV4 S3 client against Garage (stdlib only).

agentic-pipeline plan: used by scripts/pipeline-bootstrap.sh inside the
one-shot python:3.14-slim container on ai.network to seed + verify the
versioned_file object of bucket ci-artifacts (s3-resource check needs it
green). Deliberately dependency-free: MinIO's own mc image is no longer
published on Docker Hub (MinIO archived, plan sec. 2.1).

Env: S3_ENDPOINT http://host:port, S3_REGION, S3_AK, S3_SK
argv: <seed|ls> <bucket> <key> [local-file]
"""
import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.request
from urllib.parse import quote

ENDPOINT = os.environ["S3_ENDPOINT"].rstrip("/")
REGION = os.environ.get("S3_REGION", "garage")
AK = os.environ["S3_AK"]
SK = os.environ["S3_SK"]
SERVICE = "s3"


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def request(method, bucket, key, payload=b""):
    host = ENDPOINT.split("//", 1)[1]
    path = "/" + (bucket + "/" + key).lstrip("/") if key else "/" + bucket + "/"
    url = ENDPOINT + quote(path)
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    ph = hashlib.sha256(payload).hexdigest()
    hdrs = {"host": host, "x-amz-content-sha256": ph, "x-amz-date": amzdate}
    canon_hdrs = "".join(f"{k}:{v.strip()}\n" for k, v in sorted(hdrs.items()))
    signed = ";".join(sorted(hdrs))
    creq = f"{method}\n{quote(path)}\n\n{canon_hdrs}\n{signed}\n{ph}"
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n" + hashlib.sha256(creq.encode()).hexdigest()
    k = sign(("AWS4" + SK).encode(), datestamp)
    for part in (REGION, SERVICE, "aws4_request"):
        k = sign(k, part)
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(url, data=payload if method in ("PUT", "POST") else None,
                                 method=method)
    for kk, vv in hdrs.items():
        req.add_header(kk, vv)
    req.add_header("Authorization",
                   f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, SignedHeaders={signed}, Signature={sig}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read()


def main():
    op, bucket, key = sys.argv[1], sys.argv[2], sys.argv[3]
    if op == "ls":
        try:
            st, body = request("HEAD", bucket, key)
            print(f"exists: {bucket}/{key} ({st})")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print(f"absent: {bucket}/{key}")
                sys.exit(2)
            raise
    elif op == "seed":
        local = sys.argv[4]
        st, _ = request("PUT", bucket, key, open(local, "rb").read())
        print(f"put: {bucket}/{key} -> {st}")
    else:
        sys.exit("usage: s3-probe.py <seed|ls> <bucket> <key> [file]")


if __name__ == "__main__":
    main()
