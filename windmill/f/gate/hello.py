# P0 gate script. Deployed with: scripts/windmill-sync.sh push
# Webhook (auto-generated for every script, token-auth):
#   POST /api/w/kb/jobs_u/webhook/p/f/gate/hello
def main(body=None):
    return {"hello": (body or {}).get("name", "world")}
