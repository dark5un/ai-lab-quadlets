# MAXBar — menu-bar widget for MaxPresence virtual interfaces

Always-on status item ("MAX ●") in the macOS menu bar showing the live state of
the MaxPresence link and the virtual audio/camera interfaces. Pure observer:
it opens **no** audio or capture streams, so it never triggers a TCC mic/camera
prompt (owner consent policy 2026-11-12 stays intact).

## What it detects (all verified live on code-m2, 2026-11-12)

| Plane | Signal | API |
|---|---|---|
| Door link | `maxaudiod` heartbeat file: connected / reconnecting / down, tx+rx frame counts, errors, door URL | `~/Library/Application Support/MaxPresence/*.json` written by `maxaudiod.py` every 2 s |
| Audio (MaxHole) | "MAX Mic" / "MAX Out" installed + STREAMING/idle | CoreAudio name lookup + `kAudioDevicePropertyDeviceIsRunningSomewhere` ('gone') |
| Camera (P2) | "MAX Camera" installed + streaming/idle (will light up when P2 lands) | CoreMediaIO `kCMIOHardwarePropertyDevices` + `kCMIODevicePropertyDeviceIsRunningSomewhere` |

Dot colour: green = link up · orange = daemon up, link down · gray = no daemon.

### Detection pitfalls measured here (do not re-learn the hard way)
- `kAudioStreamPropertyIsActive` ('sact') on MaxHole streams is **statically 1**
  — useless as a live flag. Use device-scope 'gone' (flips exactly with streams).
- Scope-qualified 'gone' (input/output) mirrors global on the full-duplex
  virtual pipes → one flag per device is all that is honest.
- A killed daemon leaves `connected: true` in its last heartbeat; the widget's
  freshness rule (ts older than 6 s = down) correctly overrides it.

## Heartbeat schema (maxaudiod.json; any daemon may drop one, filename = name)
```json
{"pid":0,"mode":"run","door":"wss://…","connected":true,
 "started":0,"last_connect":0,"last_stat":0,
 "tx_frames":0,"rx_frames":0,"errors":0,"ts":0}
```

## Build / run / install
```sh
./build.sh                       # swiftc (CLT-only ok), ad-hoc signed .app
./build/MAXBar.app/Contents/MacOS/maxbar --selftest   # headless state dump
ditto build/MAXBar.app ~/Applications/MAXBar.app && open ~/Applications/MAXBar.app
```
Installed on code-m2 at `~/Applications/MAXBar.app` (2026-11-12).

## End-to-end verification performed
Dummy local WSS door + real `maxaudiod run --door ws://127.0.0.1:8799`:
`link: UP · tx 304 rx 304` (20 ms frames, correct rate), both MAX devices
reported STREAMING, camera correctly absent; after killing the rig: `down —
last seen 18 s ago`. Also exercised: connection-refused flapping (errors
counting, connected=false on every drop).

## Future (P2/P4)
MaxCamHost drops `maxcamhost.json` with the same schema → appears automatically.
For per-side attribution (app-writes vs bridge-reads) there is no public
CoreAudio API that distinguishes clients on one pipe; frame counters in the
heartbeat + 'gone' on the opposite device are the best available signal.
