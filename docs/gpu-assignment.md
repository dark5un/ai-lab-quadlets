# GPU assignment

This host has two NVIDIA cards and every GPU service is named after the card
it runs on. The registry (`services.json`, field `gpu`) is the source of truth;
`scripts/gpu-arbiter.py` enforces the rules when services start.

| card | UUID placeholder | services |
|---|---|---|
| RTX 5090 32 GB | `__GPU_5090_UUID__` | strata-5090, llama-cpp-5090, comfyui-5090 |
| RTX 4070 Ti 12 GB | `__GPU_4070TI_UUID__` | strata-4070ti, llama-cpp-4070ti, comfyui-4070ti, rizzo |
| both | both placeholders | strata-both |

## Rules (scripts/gpu-arbiter.py)

1. Strata owns its card(s). Starting a GPU service on strata's card moves
   strata to the other card (strata-both drops to the other card). Strata off
   stays off.
2. Starting a single-card strata variant stops every other service on that
   card, except ComfyUI, which moves to the other card.
3. strata-both stops every GPU service.
4. ComfyUI runs on the card strata is not on (strata off: the 4070 Ti).
5. Non-strata services may share a card.

Use `ai-lab start|stop|toggle <name>` (or the AI Lab bar widget); add
`--dry-run` to see the plan. The strata units' `Conflicts=` is a backstop for
a bare `systemctl start`, which stops the other side instead of moving it.

## Pinning

- Placeholders are filled by `scripts/render-units.sh` from `nvidia-smi`,
  matching cards by **name** (never by index).
- Strata units add the CDI device by UUID (`AddDevice=nvidia.com/gpu=GPU-...`)
  so nvidia-smi (which Strata's setup reads) and CUDA see the same cards.
  Safe here because the CDI spec is `/var/run/cdi/nvidia.yaml`, regenerated
  every boot by `nvidia-cdi-refresh`.
- Every other GPU service passes all devices and pins at the CUDA layer:
  `AddDevice=nvidia.com/gpu=all` + `Environment=CUDA_VISIBLE_DEVICES=<uuid>`.
  This survives a stale static `/etc/cdi/nvidia.yaml` (minor numbers of
  /dev/nvidiaN can reshuffle at driver load).

## Replaced a card?

Update the name match in `scripts/render-units.sh` (and the placeholders if
the card model changes), re-render the units, `systemctl --user daemon-reload`.
