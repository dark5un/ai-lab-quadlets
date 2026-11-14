# maxaudiod — P1 prototype (Python)

launchd-ready audio bridge for MaxHole (docs/mac-virtual-devices-plan.md):

- reads **MAX Out** input (meeting audio) -> WSS binary `A` frames, s16le 48k mono, 20 ms
- reads WSS binary `A` frames (Max's voice, s16le 24k mono) -> writes **MAX Mic** output
- native-rate trick: MaxHole offers 24000+48000 (V-4) so the Mac side never resamples
- reconnect with capped backoff; JSON control frames per protocol (`hello` on connect)

## Run

    uv run maxaudiod.py loopback-test          # device verification, no server needed
    uv run maxaudiod.py run --door wss://ai.<tailnet>:84xx   # door URL arrives with P0

Requires `portaudio` (brew) for sounddevice.

## Evidence harnesses

These write into the real door and into the MAXHole devices; none of them stands in for a protocol
peer (a system player into MAX Out is byte-for-byte what a meeting app does).

    gate1-turn.sh [OUT_DIR] ["utterance"]        # one turn through the door, recorded off MAX Mic
    gate1-mic-loopback.sh [OUT_DIR] [SECONDS]    # does a known tone written into MAX Mic survive?
    run-barge.sh <label> [gate:on|off] ["utt1"] ["utt2"]   # scripted peer interrupts mid-reply

`run-barge.sh` needs playback into MAX Out only (no microphone TCC grant). It leaves the link down;
restore with `{"gate":false,"link":"up"}` in `~/Library/Application Support/MaxPresence/cmd-maxaudiod.json`.

## P1 -> P2 handoff note

When P0's plexpipe door is live, the loopback-test gate below must pass first:
each pipe loops to itself, zero cross-pipe leakage (V-3 feedback safety).
