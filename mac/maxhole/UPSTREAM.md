Upstream: https://github.com/ExistentialAudio/BlackHole
Version:   0.7.1
Commit:    6008d295ff00c8b57412a23564619963f4ecbeac (2026-11-07)
File:      BlackHole/BlackHole.c -> src/maxhole.c
License:   GPLv3 (LICENSE copied verbatim from upstream)
Local changes (2026-11-12, Hermes-on-Mac):
 - Per-device ring buffers (gRingBuffers[2])
 - Per-device zero-time-stamp clock arrays
 - Per-device DoIO lastOutputSampleTime/isBufferClear state
 - device_index() helper
 - Names/bundle-id via build.sh -D constants (MaxHole / MAX Mic / MAX Out)
 - "BlackHole Box" -> "MaxHole Box"
