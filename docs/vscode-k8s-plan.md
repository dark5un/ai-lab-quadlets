# Per-environment VS Code servers on Kubernetes (rootless Podman host) — feasibility & POC (v1, 2026-11-10)

Goal: evaluate running *browser-based* VS Code servers (`code-server` /
`code serve-web` — no desktop X11) one-per-environment inside a Kubernetes
cluster on THIS rootless-Podman Arch box (ai-lab quadlet host), with a
Concourse-driven create/destroy/expire lifecycle. A live POC was run end to
end and torn down; every version and flag below was resolved by an in-session
probe (see **Verification Appendix**).

## Verdict

**Feasible and demonstrated.** `kind` v0.33.0 with the rootless Podman
provider runs on this box with zero host changes (all documented
prerequisites — cgroup v2, systemd 262 `Delegate=yes`, iptables modules,
raised inotify limits — were already satisfied by the existing stack). A
throwaway cluster `vscode-poc` hosted two namespaces (`env-alice`, `env-bob`),
each running `codercom/code-server:4.145.2` with its own connection token from
a `Secret`, `emptyDir` (ephemeral) storage, small resource requests, and
NodePorts 30301/30302 forwarded to **host loopback only** via kind
`extraPortMappings`. Auth behavior verified live (valid token → session,
invalid/cross-env token → rejected). Cluster deleted and absence proven.

However, for the *current single persistent dev box*, the existing quadlet
`systemd-vscode` (docs/vscode-server-plan.md) stays the production path:
kind adds a Kubernetes layer you only need if you want **many short-lived,
per-user/per-task environments with automated lifecycle**. The Concourse
cleanup design (§Pipeline sketch) is what makes that lifecycle cheap.

## Options evaluated

| option | root needed? | status | notes |
|---|---|---|---|
| **kind + podman provider (rootless)** | no | **CHOSEN — POC ran live** | `KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster`; rootless supported since kind 0.11, Podman ≥3.0 (host: 6.1.4). Single control-plane container, `privileged: true` inside the userns — fine rootless. Loopback-only API + `extraPortMappings` for ingress (upstream explicitly warns against wider exposure). |
| k3s directly on host | **yes** (installs systemd units, CNI, possibly reboots deps) | rejected as-is | touches host boot state; conflicts with quadlet stack's port/module assumptions. |
| **k3s-in-container = k3d** | no (v5.9.0 probed) | viable fallback | k3d drives the Podman Docker-API socket (`DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`). Upstream marks Podman support *experimental*; rootless needs `Delegate=cpu cpuset io memory pids` (host has blanket `Delegate=yes` already) and a DNS-enabled `k3d` network. Not exercised in the POC. |
| minikube `--driver podman` | no | not evaluated | same class as k3d; heavier add-on model; skipped to keep one container-K8s path proven. |
| `podman play kube` (host Podman) | no | **REJECTED — it is not Kubernetes** | no API server, scheduler, Service VIPs/DNS reconciliation, `kubectl`, or Secret propagation loop; one-shot Pod translation only. None of the pipeline lifecycle primitives (namespaces, label selectors, cascade delete, `kubectl wait`) exist. |
| microk8s | yes-ish | REJECTED | snap-based; no snap on Arch. |
| vanilla kubeadm | **yes** | REJECTED | root-level systemd + kernel/sysctl surgery; unacceptable on the stack host. |

## POC evidence (live, 2026-11-10)

Toolchain (all binaries under `~/.hermes/cache/scratch/vscode-k8s/bin/`, nothing installed system-wide, no `~/.kube` created — kubeconfig kept at scratch path via `KUBECONFIG`):

- `kind v0.33.0` (GitHub latest; sha256 verified against release asset), `kubectl v1.37.2` (dl.k8s.io `stable.txt`; sha256 verified).
- Node image pinned with digest from kind v0.33.0 release notes: `kindest/node:v1.37.0@sha256:a1ed56…80ae5`.

Cluster:

```
KIND_EXPERIMENTAL_PROVIDER=podman KUBECONFIG=$D/kubeconfig kind create cluster --config kind-config.yaml --wait 300s
→ node Ready, v1.37.0, containerd://2.3.4, API at https://127.0.0.1:46661 (loopback)
```

Workloads (`envs.yaml`, tokens rendered from `openssl rand -hex 16` into
per-namespace `Secret code-server-auth`, never written to git):

- `codercom/code-server:4.145.2` (GitHub latest v4.145.2; Docker Hub manifest HEAD 200; pulled on node at digest `sha256:09565f…7c1c`).
- Flags live-verified from the image itself: `--auth [password, none]`, `--bind-addr host:port`, `--cert` (self-signed auto-generated).
- `requests: cpu 100m / memory 256Mi`, `limits: cpu 1 / memory 1Gi`; workspace = `emptyDir` (ephemeral by design).

Exposure & auth probes (host loopback only; `ss -ltn` showed `127.0.0.1:30301`, `127.0.0.1:30302`; kind docs: for NodePort+mapping, `containerPort == nodePort`):

```
GET /                      → 302 → /login          (unauth redirect works)
POST /login wrong token    → 200 (login page re-rendered = rejected)
POST /login env token      → 302 (session issued)
GET / authed               → 200 at /?folder=/home/coder, page contains "code-server"
alice token on bob port    → 200 rejected          (per-env tokens truly isolated)
```

Teardown proof:

```
kind delete cluster --name vscode-poc → "Deleted nodes: [vscode-poc-control-plane]"
kind get clusters                     → "No kind clusters found."
podman ps -a --filter name=vscode-poc → none
ss -ltn | grep -E '3030[12]'          → ports released
podman volume ls | grep kind          → none
```

## Per-env model (what a production shape would look like)

- Long-lived kind cluster created once out-of-band (or a k3d cluster as fallback).
- **Port pool caveat:** kind `extraPortMappings` are static per cluster — you must pre-create a mapping pool (e.g. 30301–30320, `listenAddress: "127.0.0.1"`) and assign one NodePort per env; env create/destroy never touches the cluster config. 31xx host ports are consumed by the quadlet stack, and 3124+ by s3-webdav, so 30xxx NodePort-pool numbers are the right namespace for kind.
- Each env = Namespace `env-<user>` + `Secret code-server-auth` (token) + Deployment + NodePort Service, namespaced label `vscode.ai-lab/env=true` and annotation `vscode.ai-lab/expires-at=<epoch>`.
- Access rides the existing Tailscale Services doors pattern (svc:vscode style), NOT raw kind exposure — same door model as :8443 today. The cluster API itself stays loopback/host-internal.

## Pipeline sketch (Concourse, draft — NOT set live)

Draft saved at `~/.hermes/cache/scratch/vscode-k8s/vscode-envs.yml`. Jobs:

- `create-env` (manual only): render template (user, NodePort from pool, token via `openssl rand -hex 16`), `kubectl apply`, label+annotate ns, `kubectl wait --for=condition=Ready …`, emit token through a secret channel only (never build logs/git).
- `destroy-env` (manual only): `kubectl delete namespace env-<user> --wait=true`, then prove `NotFound`.
- `renew-env` (manual only): bump `expires-at`.
- `expire-idle-envs` (the only time-triggered job, `time` resource 30m): list `-l vscode.ai-lab/env=true`, delete any ns whose `expires-at < now`.
- Task images curl the hash-pinned kubectl from dl.k8s.io (same probe pair used in the POC); `fly` invocations need `--non-interactive` (fly 8.3.3 TUI confirmations).
- `kubectl delete namespace` cascade itself was not exercised individually in the POC (whole-cluster `kind delete` was) — standard Kubernetes semantics, marked not-live-verified here.

## Security caveats

- kind upstream: spin-down/recreate is their security update story; "expose to loopback only". The POC honors that (API on `127.0.0.1`, NodePort bindings on `127.0.0.1` with `listenAddress`; external reach must go through the existing tailscale door pattern with TLS).
- code-server `password` auth is a single static token + cookie session; no 2FA, brute force soft (200 re-render, no lockout observed). Acceptable behind a tailnet door; the `--cert` flag gives self-signed TLS termination inside the pod if the door does not already terminate.
- Secrets in etcd are stored base64, not encrypted at rest in the stock kind setup (no `--encryption-provider-config` plumbed) — treat namespace admin == token read. Not separately verified live; flag it.
- Rootless constraints (kind rootless docs): no block-storage/NFS mounts, privileged host ports unavailable (hence 30xxx pool), default Podman `pids_limit=4096` per container is fine for one code-server pod but matters for ingress controllers; host here already has the needed cgroup delegation and raised inotify limits — a fresh box would need the documented tune-ups.
- The kind node is `privileged: true` inside the user namespace: pods on that cluster are effectively host-namespace-capable containers — do NOT mix untrusted workloads with GPU/host-mount `extraMounts` in the same cluster.
- GPU arbiter: nothing in this POC claimed a GPU; the quadlet `scripts/gpu-arbiter.py` / `services.json` registry remains untouched. Any future k8s GPU env must register with the arbiter before it exists.

## GPU passthrough via CDI into kind pods — status

- Host already has an NVIDIA-generated CDI spec: `/etc/cdi/nvidia.yaml`, `kind: nvidia.com/gpu`, devices `0`, `1` (the 5090 + 4070 Ti), and `all` — probed live; UUIDs not reproduced here.
- `kindest/node:v1.37.0` runs **containerd 2.3.4** (probed via `containerd --version` inside the node). NVIDIA's k8s-test-infra docs state containerd 2.x enables CDI by default (`/etc/cdi`, `/var/run/cdi` spec dirs) — **documented claim, accepted on citation**.
- But the stock kind node has **no CDI spec and no NVIDIA runtime inside it** (probed: `/etc/cdi` absent in the node; no nvidia bind mounts on the node container). The path that NVIDIA's own kind demos use is: install the container toolkit *inside the node* (or mount the spec via kind `extraMounts`) + driver visibility — their demos assume **rootful Docker**, not rootless Podman.
- **UNVERIFIED:** whether a `privileged` kind node under *rootless* Podman exposes host `/dev/nvidia*` usable by the in-node toolkit (userns device-access + arbiter rules make this likely painful). Verdict: **do not plan GPU VS Code envs on kind**; keep GPU work on the proven quadlet path (existing `systemd-vscode` box already carries host-Podman passthrough for GPU pod launches). Revisit only if a k8s-GPU requirement becomes real.

## Reproducing the POC

Artifacts kept (outside the repo, by design): `~/.hermes/cache/scratch/vscode-k8s/` —
`bin/kind`, `bin/kubectl`, `kind-config.yaml`, `envs.yaml` (token placeholders),
`envs.rendered.yaml` + `tokens.env` (**chmod 600; contains live tokens — scrub or
delete after review**), `probe2.sh`, `verify-poc.sh`, `create.log`, `vscode-envs.yml`
(pipeline draft), `kubeconfig`.

## Verification appendix (claim → probe → observed)

| # | claim | probe command (in-session) | observed snippet |
|---|---|---|---|
| 1 | kind latest = v0.33.0 | `curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \| grep tag_name` (via assets JSON) | `"tag_name": "v0.33.0"` published 2026-08-26 |
| 2 | kubectl stable = v1.37.2 | `curl -fsSL https://dl.k8s.io/release/stable.txt` | `v1.37.2` |
| 3 | kubectl binary integrity | `curl -fsSL …/v1.37.2/bin/linux/amd64/kubectl.sha256` then `sha256sum -c kubectl.sha256` | `kubectl: OK` |
| 4 | kind binary integrity | `curl -fsSLO …/v0.33.0/kind-linux-amd64.sha256sum; sha256sum -c` (binary renamed first) | `kind: OK` |
| 5 | rootless Podman supported by kind; env-var name | https://kind.sigs.k8s.io/docs/user/rootless/ (fetched) | "`KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster`"; Podman ≥3.0; cgroup v2; systemd ≥252 delegation |
| 6 | host satisfies prerequisites | `podman info \| grep -i cgroupversion`; `systemctl --version`; `lsmod \| grep …`; `sysctl fs.inotify…`; `systemctl show user@1000.service -p Delegate` | `cgroupVersion: v2`; `systemd 262`; `ip_tables/iptable_nat/iptable_filter/br_netfilter` loaded; `524288/1024`; `Delegate=yes` |
| 7 | default node image + supported tags | kind v0.33.0 release body grep | "default node image is now `kindest/node:v1.37.0@sha256:a1ed56cf…`" (also v1.36.4, v1.35.8, v1.34.11) |
| 8 | code-server latest & image exists | `api.github.com/repos/coder/code-server/releases/latest`; Docker Hub anonymous-token `HEAD …/v2/codercom/code-server/manifests/4.145.2` | `v4.145.2 (2026-11-07)`; `HTTP/2 200` (note: anonymous `tags/list` returns 401 → probe per-tag manifests instead) |
| 9 | `lts` tag does NOT exist for codercom/code-server | same manifest probe, tag `lts` | `codercom/code-server:lts -> HTTP 404` (pin numeric tags) |
| 10 | cluster creation | `KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --config kind-config.yaml --wait 300s` | `rc=0`; `kind get clusters` → `vscode-poc` |
| 11 | node runtime/version | `kubectl get nodes -o wide`; `podman exec vscode-poc-control-plane containerd --version` | `v1.37.0 … containerd://2.3.4`; `containerd … v2.3.4` |
| 12 | API loopback-only | `kubectl cluster-info` | `Kubernetes control plane is running at https://127.0.0.1:46661` |
| 13 | node container privileged=true (GPU/CDI context) | `podman inspect vscode-poc-control-plane --format '{{.HostConfig.Privileged}} {{.HostConfig.NetworkMode}}'` | `true bridge` |
| 14 | code-server flags real, not folklore | `kubectl -n env-alice exec deploy/code-server -- code-server --help` | `--auth … [password, none]`; `--bind-addr … host:port`; `--cert … self signed … generated` |
| 15 | host bindings loopback only | `ss -ltn \| grep -E '3030[12]'` | `LISTEN 127.0.0.1:30301`, `127.0.0.1:30302` |
| 16 | auth gate works per env | curl POST/GET sequence (see POC evidence) | `302→/login`, wrong `200`, good `302`, authed `200 …?folder=/home/coder`, cross-env token `200` rejected |
| 17 | requests/limits + emptyDir applied | `kubectl get pod -o jsonpath='{.items[0].spec.containers[0].resources}'` / `{.spec.volumes}` | `{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}`; `[{"emptyDir":{},"name":"workspace"},…]` |
| 18 | image pulled by digest on node | `kubectl get pods -A -l app=code-server -o jsonpath=…imageID` | `docker.io/codercom/code-server@sha256:09565f9e…3d7c1c` |
| 19 | teardown complete | `kind delete cluster --name vscode-poc`; then `kind get clusters`, `podman ps -a --filter name=vscode-poc`, `ss`, `podman volume ls` | "Deleted nodes: […]", "No kind clusters found.", no containers, ports released, no volumes |
| 20 | kind supports fixed API port + listenAddress + NodePort==containerPort rule | kind docs configuration page (fetched) | `networking: apiServerAddress/apiServerPort`; `extraPortMappings.listenAddress: "127.0.0.1"`; "the kind node `containerPort` and the service `nodePort` needs to be equal" |
| 21 | host CDI spec exists (GPU §) | `grep -E 'name:|kind:' /etc/cdi/nvidia.yaml` | `kind: nvidia.com/gpu`, devices `0`,`1`,`all` (+2 GPU-UUID entries, not reproduced) |
| 22 | no CDI spec inside stock kind node | `podman exec vscode-poc-control-plane ls /etc/cdi` | `No such file or directory` |
| 23 | MCR `code serve-web`-capable images exist (alternative) | `curl -o /dev/null -w '%{http_code}' …/v2/devcontainers/{typescript-node,python}/manifests/latest` | both `HTTP 200` (note: `code serve-web` has no built-in auth → token gate must come from a proxy or the door; code-server chosen instead) |
| 24 | fly needs `--non-interactive` | prior live-verified stack fact (docs/agentic-pipeline-plan.md) | bubbletea TUI confirmations; stdin pipes fail |
| 25 | containerd 2.x CDI-on-by-default | NVIDIA k8s-test-infra docs (cited in GPU §) | documented claim; config not directly observed inside node — flagged |

*No tailnet FQDNs, real IPs, GPU UUIDs, or token values appear in this file.*
