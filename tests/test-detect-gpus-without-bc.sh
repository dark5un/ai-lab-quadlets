#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/detect-gpus-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config/llama.cpp" "$TMP/config/llama.cpp-research"
cp "$ROOT/config/llama.cpp/service.env.example" "$TMP/config/llama.cpp/service.env.example"
cp "$ROOT/config/llama.cpp/service.env.example" "$TMP/config/llama.cpp-research/service.env.example"

cat > "$TMP/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '0, NVIDIA GeForce RTX 5090, GPU-34466eba-2642-c31a-2e44-6451b6a6b425, 32607 MiB' \
  '1, NVIDIA GeForce RTX 4070 Ti, GPU-58e5f98d-a4f4-4cff-a9fc-16df0667d2fd, 12282 MiB'
STUB
cat > "$TMP/bin/bc" <<'STUB'
#!/usr/bin/env bash
echo 'bc intentionally unavailable for this regression test' >&2
exit 127
STUB
chmod +x "$TMP/bin/nvidia-smi" "$TMP/bin/bc"

PATH="$TMP/bin:/usr/bin:/bin" bash "$ROOT/scripts/detect-gpus.sh" \
  --output-dir "$TMP/quadlets" --config-dir "$TMP/config"

grep -q '^LLAMA_ARG_CTX_SIZE=262144$' "$TMP/config/llama.cpp/service.env"
grep -q '^LLAMA_ARG_CTX_SIZE=32768$' "$TMP/config/llama.cpp-research/service.env"
test -f "$TMP/quadlets/llama-cpp-main.container"
test -f "$TMP/quadlets/llama-cpp-research.container"
printf '%s\n' 'GPU detection passed without bc; both GPU configs generated.'
