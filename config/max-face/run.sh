#!/bin/sh
# max-face NIM single-stream runner (pattern: Audio2Face-3D-Samples
# quick-start docker-compose, single-unit variant). First run downloads
# weights (NIM_CACHE_PATH=/tmp/nim-cache -> max-face-cache volume) and
# generates batch-1 TRT engines (/tmp/a2x -> same volume); later runs are
# instant. Engine cache invalidation: remove *.trt from max-face-cache.
set -e
cd /opt/nvidia/a2f_pipeline
export LD_LIBRARY_PATH=/usr/local/lib/:/root/.local/lib/
if [ -z "$(find /tmp/a2x -name '*.trt' -print -quit 2>/dev/null)" ]; then
  echo "[max-face] no cached TRT engines; generating (this can take a while)..."
  ./service/generate_trt_models.py \
    --stylization-config /mnt/configs/james_stylization_config.yaml \
    --advanced-config /mnt/configs/advanced_config.yaml
fi
exec a2f_pipeline.run \
  --stylization-config /mnt/configs/james_stylization_config.yaml \
  --deployment-config /mnt/configs/deployment_config.yaml \
  --advanced-config /mnt/configs/advanced_config.yaml
