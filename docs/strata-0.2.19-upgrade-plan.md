# Strata engine upgrade plan: 0.1.55 (pin c62d5e3a) -> v0.2.19 (engine 0.1.65)

Written 2026-11-22 for a remote executor with shell access to the `ai` box (Arch, RTX 5090 + RTX 4070 Ti).
Execute top to bottom. Every step has a gate: if a gate fails, STOP and roll back (section 8) — do not improvise.

## 0. Ground truth (verified 2026-11-22, re-verify in step 2)

- Strata repo (pure upstream snapshot, ZERO unique commits): `~/workspace/github.com/dark5un/strata-harness`
  - current pin: commit `c62d5e3a` (2026-10-31), engine component inside the image: `0.1.55-linux-x86_64-cuda-cuda13`
  - target: tag `v0.2.19` = commit `c6f6427d9de9016fd92d13e29740f65625261df7` (upstream tip as of 2026-11-22, Niko1221/Strata)
- Image used by ALL strata quadlets: `localhost/strata-harness:multi`
- Active unit: `strata-5090-1m.service` (container `systemd-strata`, PRESET=strata-5090-1m, MODEL=IQ3_S,
  CONTEXT=1048576, KV=int8, PARALLEL=1, host port 0.0.0.0:11434). All other strata units are inactive.
- API key: `~/.config/containers/config/strata/service.env` (API_KEY=...). Read it from the file; never type
  secrets into logs, and never "repair" a key that looks wrong.
- Tailnet door: `https://ai.<tailnet>.ts.net:8447/v1` (tailscale serve -> 127.0.0.1:11434).
- IMPORTANT: interactive agent sessions run on this very model. Do NOT run this upgrade from a session
  served by strata on this box (this plan is executed remotely — that's already satisfied).

## 1. What you gain and why it's safe

- 0.2.14/0.2.16: prefill runs on Strata's own NVIDIA kernels — measured ~+15% prompt throughput on RTX 5090
  class cards; engine code rewritten off llama.cpp kernels with token-identical outputs on verification prompts.
- DFlash2 drafter packs exist specifically for qwen3.8-flash-next (optional follow-up, section 7).
- Models/weights/settings are host volumes and survive untouched (upstream release notes confirm).

## 2. Preflight (read-only)

```bash
R=~/workspace/github.com/dark5un/strata-harness
KEY=$(awk -F= '/^API_KEY=/{print $2}' ~/.config/containers/config/strata/service.env)
git -C "$R" status --short            # must be EMPTY
git -C "$R" rev-parse HEAD            # must be c62d5e3a... (else investigate before continuing)
podman ps --format '{{.Names}} {{.Image}}' | grep strata   # systemd-strata on :multi
curl -s http://127.0.0.1:11434/v1/models -H "Authorization: Bearer $KEY" | head -c 300  # baseline answers
```

Baseline latency (record for later comparison):

```bash
time curl -s http://127.0.0.1:11434/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"IQ3_S","max_tokens":128,"temperature":0,"messages":[{"role":"user","content":"Write a haiku about disk arrays."}]}' \
  > /tmp/strata-baseline.json
```

Gate: working tree clean, models endpoint answers.

## 3. Move the pin to v0.2.19

```bash
cd ~/workspace/github.com/dark5un/strata-harness
git fetch https://github.com/Niko1221/Strata main --tags
git merge-base --is-ancestor HEAD v0.2.19 && echo FAST-FORWARD-OK || echo "HISTORY DIVERGED - STOP"
git checkout v0.2.19        # detached tag = the pin; note new hash
git rev-parse HEAD          # expect c6f6427d9de9016fd92d13e29740f65625261df7
```

Gate: FAST-FORWARD-OK printed, HEAD == c6f6427d9...

## 4. Build the new image (leave old tag in place)

Preserve rollback target FIRST:

```bash
podman tag localhost/strata-harness:multi localhost/strata-harness:0.1.55-c62d5e3a
```

Build (this layout changed at 0.2.16: the source Dockerfile now lives at `tools/docker/Dockerfile.src`,
the root `Dockerfile` no longer exists; the 0.2.1 "missing git in terminal stage" workaround is OBSOLETE —
Dockerfile.src installs git itself and takes STRATA_COMMIT explicitly):

```bash
cd ~/workspace/github.com/dark5un/strata-harness
podman build \
  -f tools/docker/Dockerfile.src \
  --ignorefile tools/docker/Dockerfile.src.dockerignore \
  --build-arg CUDA_ARCHITECTURES="120;89" \
  --build-arg CUDA_IMAGE=docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04 \
  --build-arg RUNTIME_BASE=docker.io/library/ubuntu:24.04 \
  --build-arg "STRATA_COMMIT=$(git rev-parse HEAD)" \
  -t localhost/strata-harness:0.2.19 .
```

Expect ~25-40 min compile. Gate:

```bash
podman run --rm localhost/strata-harness:0.2.19 ls /opt/strata/components/engine/
# expect a 0.1.65-linux-x86_64-cuda-cuda13 (or plain 0.1.65...) folder
```

If the build fails on a CMake/compile error: do NOT edit sources. Capture the error, roll back the pin
(`git checkout c62d5e3a`), and report — the old `:multi` is untouched, no service downtime.

## 5. Canary on the idle 4070 Ti (production keeps running)

The 4070 Ti device id and per-variant env come from the rendered unit file — read them, don't hardcode:

```bash
GPU4070=$(sed -n 's/^AddDevice=nvidia\.com\/gpu=//p' ~/.config/containers/systemd/strata-4070ti.container)
KEY=$(awk -F= '/^API_KEY=/{print $2}' ~/.config/containers/config/strata/service.env)
D=~/.local/share/strata
podman run -d --name strata-canary \
  --device "nvidia.com/gpu=$GPU4070" \
  --ulimit memlock=-1 --shm-size=2g --stop-timeout 120 \
  -p 127.0.0.1:11435:8080 \
  -e FAMILY=qwen -e MODEL=IQ3_S -e VISION=cpu -e "API_KEY=$KEY" \
  -e PRESET=strata-4070ti -e MODEL_PATH=/data/models/IQ3_S -e GPU=0 \
  -e CONTEXT=262144 -e KV=int8 -e PARALLEL=2 \
  -v $D/models:/data/models:z -v $D/mtp:/data/mtp:z -v $D/packs:/data/packs:z \
  -v $D/Strata-data:/data/Strata-data:Z -v $D/config-4070ti:/data/config:Z \
  -v $D/state:/data/state:Z -v $D/install:/data/install:Z -v $D/home:/data/home:Z \
  localhost/strata-harness:0.2.19 /opt/strata/entrypoint.sh run
```

Load takes minutes (84 GB IQ3_S; first-time page cache is shared). Watch:

```bash
podman logs -f strata-canary          # until server is up
until curl -sf http://127.0.0.1:11435/v1/models -H "Authorization: Bearer $KEY" >/dev/null; do sleep 10; done
```

Run the same haiku/latency probe as step 2 against :11435, and a long-prompt prefill probe
(e.g. paste ~8K tokens) to compare prompt tok/s vs baseline. Gate: canary healthy, outputs coherent,
prefill noticeably faster (expect ~+15% from 0.2.14+ kernels), no CUDA errors in `podman logs`.

Cleanup: `podman rm -f strata-canary` (this frees the 4070 Ti; do not leave it running).

## 6. Cutover (brief downtime: stop -> retag -> start)

```bash
systemctl --user stop strata-5090-1m.service
podman tag localhost/strata-harness:0.2.19 localhost/strata-harness:multi
systemctl --user start strata-5090-1m.service
# NOTE: units cap at 2 starts per 20 min (StartLimitBurst=2). If it fails once, fix the cause before
# retrying; after a burst hit run: systemctl --user reset-failed strata-5090-1m.service
```

Verify (all three must pass):

```bash
KEY=$(awk -F= '/^API_KEY=/{print $2}' ~/.config/containers/config/strata/service.env)
curl -s http://127.0.0.1:11434/v1/models -H "Authorization: Bearer $KEY"
curl -sk https://ai.<tailnet>.ts.net:8447/v1/models -H "Authorization: Bearer $KEY"   # from a tailnet box
podman exec systemd-strata sh /opt/strata/healthcheck.sh && echo HEALTHY
journalctl --user -u strata-5090-1m -n 30 --no-pager   # engine banner should say 0.1.65
```

Then a real chat probe and compare tok/s to step 2 baseline.

## 7. Optional follow-up (report only, don't do unattended): DFlash2 drafter

Upstream ships `qwen3.8-flash-next-dflash2.strata1.q4_0-bf16sel.pack` drafter packs (speculative decoding,
862 MB together). Check `ls ~/.local/share/strata/mtp` and the Terminal's drafter setting; enabling it is a
separate change with its own restart — note its availability in your report instead.

## 8. Rollback (any gate fails)

```bash
systemctl --user stop strata-5090-1m.service 2>/dev/null
podman tag localhost/strata-harness:0.1.55-c62d5e3a localhost/strata-harness:multi
systemctl --user start strata-5090-1m.service
cd ~/workspace/github.com/dark5un/strata-harness && git checkout c62d5e3a
# verify per step 6. The :0.2.19 image may stay for inspection.
```

## 9. After success — housekeeping for the repo/owner (not the engine)

1. Patch `scripts/install-strata.sh` to the 0.2.16+ layout (so future `--rebuild` works):
   - existence check: `tools/docker/Dockerfile.src` + `tools/docker/entrypoint.sh` instead of root `Dockerfile`/`docker/entrypoint.sh`
   - delete the 0.2.1 `TMPD` git-workaround block entirely (obsolete; upstream installs git in the terminal stage now)
   - add to the podman build line: `-f "$STRATA_REPO/tools/docker/Dockerfile.src"` and
     `--ignorefile "$STRATA_REPO/tools/docker/Dockerfile.src.dockerignore"`
   - commit; record the pin: "strata v0.2.19 (engine 0.1.65), commit c6f6427d9de9016fd92d13e29740f65625261df7"
2. Optionally fast-forward the fork: `git -C <harness> push origin HEAD:main --force-with-lease` — ASK the owner first
   (the checkout is now detached at a tag).
3. Report back to the owner: engine version in banner, prefill/decode tok/s before/after, healthcheck results.

## Known pitfalls

- Root `Dockerfile` does NOT exist at v0.2.19 — always `-f tools/docker/Dockerfile.src` with podman.
- `--ignorefile` matters: v0.2.19 has no root `.containerignore`; without it the whole `.git` lands in the build context.
- Do not touch `service.env`, API keys, or `/data/models` layout — engine-only upgrade.
- Do not restart the 4070 Ti/coder units during cutover; they are idle and pick up the new image on next start.
- The `ai-lab` bar widget / `gpu-arbiter.py` is the sanctioned way to move GPU services; for a same-variant
  restart a plain `systemctl --user stop/start` is fine.
