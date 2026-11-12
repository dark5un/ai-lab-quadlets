# MaxHole — CoreAudio HAL driver (private GPLv3 fork of BlackHole 0.7.1)

One driver bundle exposing exactly two virtual devices (docs/mac-virtual-devices-plan.md V-2/V-3):

- **MAX Mic** — agent plays Max's voice INTO its output side; the meeting app selects it as microphone (input side).
- **MAX Out** — meeting's speaker output goes INTO its output side; the agent records the meeting from its input side.

Sample rates 48000/24000, 2 channels, latency 512 frames. Ad-hoc signed; installs to `/Library/Audio/Plug-Ins/HAL/MaxHole.driver` via `build/MaxHole-*.pkg`.

## Fork change vs upstream (important)

Upstream BlackHole's 2Sink mode shares ONE ring buffer, ONE zero-time-stamp clock, and ONE
clear/last-write state across both devices — `BlackHole_DoIOOperation`/`GetZeroTimeStamp` ignore
`inDeviceObjectID`. For two-pipe loopback that is acceptable only if the pipes are never live at
the same time; MaxHole REQUIRES isolation (V-3: "two separate pipes means no self-echo loop").
This fork makes per-device: ring buffer, zero-time-stamp clock (anchor/previous ticks/counters),
and the DoIO `lastOutputSampleTime`/`isBufferClear` state. Volume/mute/clock-source/sample-rate
remain GLOBAL to the plugin (both devices share them) — fine for P1, revisit if Meet's per-device
controls matter.

## Build / install

    ./build.sh
    sudo installer -pkg build/MaxHole-0.1.0.pkg -target /
    sudo killall -9 coreaudiod        # required after every MaxHole change (pitfall list)

Verify: `system_profiler SPAudioDataType | grep -A3 -E "MAX Mic|MAX Out"`

## License / provenance

GPLv3 (LICENSE). Upstream pinned — see UPSTREAM.md. Fork must stay PRIVATE (plan pitfall).
