#!/usr/bin/env python3
"""windmill-vars.py - create/update the Windmill workspace variables from the
stack's own config files (the variable values are NOT in the repo; sync push
must run with --skip-variables or it deletes them - verified 2026-11-05).
Idempotent: create; on 'already exists' -> update. Never prints values."""
import json, urllib.request, pathlib

CONF = pathlib.Path.home() / ".config/containers/config"
tok = (CONF / "windmill" / "agent-token").read_text().strip()
router_key = (CONF / "llama-cpp" / "keys.txt").read_text().splitlines()[0].strip()


def api(method, path, body=None):
    req = urllib.request.Request("http://127.0.0.1:3117/api" + path, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + tok)
    data = json.dumps(body).encode() if body is not None else None
    try:
        r = urllib.request.urlopen(req, data=data, timeout=30)
        return r.status, r.read().decode()[:150]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def put_var(path, value, description):
    st, msg = api("POST", "/w/kb/variables/create",
                  {"path": path, "value": value, "is_secret": True,
                   "description": description})
    if st in (200, 201):
        print("created", path)
        return
    if "already exists" in msg or st == 409:
        st2, m2 = api("PUT", "/w/kb/variables/update/" + path,
                      {"value": value, "is_secret": True, "description": description,
                       "name": path.split("/")[-1], "path": path})
        print("updated", path, st2, m2[:80] if st2 >= 400 else "")
    else:
        print("FAIL", path, st, msg)


put_var("f/kb/router_key", router_key,
        "llama-cpp router shared key (KB LLM roles; mirrors config/llama-cpp/keys.txt line 1)")
