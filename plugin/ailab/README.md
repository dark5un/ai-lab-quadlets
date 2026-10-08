# AI Lab

A Ryoku shell plugin (`ailab`) that puts the ai-lab-quadlets stack on the QS
Bar: a glyph with a running/total count, and a panel listing every registered
service with a live state dot, its host port, health, and a START/STOP switch.

## What it does

- **Service** (`service/Main.qml`): polls `bin/ai-lab status --json` on a
  timer (default 10 s) and exposes the parsed rows to both views.
- **Widget** (`content/Widget.qml`): the bar glyph plus the running/total
  count. A left click only opens the panel; it never changes state.
- **Panel** (`content/Panel.qml`), three sections; every control is a
  labelled segmented row (`content/Segmented.qml`) whose segments share the
  row's width, so nothing runs off the card at any option count:
  - **STRATA**: a status line per instance (main, coder) with an OPEN button
    in the same column as the service rows' (the instance's web app: chat,
    Monitor tab, settings; live once the model is ready), then
    CARD `OFF | 5090 | 4070 TI | BOTH` (`bin/ai-lab strata <variant>`),
    CONTEXT `256K | 524K | 1M` (the 5090 variants strata-5090,
    strata-5090-524k, strata-5090-1m; picking one moves Strata to the 5090)
    and CODER `OFF | ON · 4070 TI` (strata-coder, port 11439, beside a 5090
    variant). Hovering a choice shows the arbiter's plan under the controls
    (`bin/ai-lab ... --dry-run`: "→ starts strata-5090-1m · stops rizzo").
  - **GPU SERVICES**: LLAMA `OFF | 5090 | 4070 TI | BOTH` (single cards toggle
    independently via `bin/ai-lab toggle llama-cpp-<card>`, BOTH is the
    exclusive layer-split server, OFF runs `bin/ai-lab stop llama-cpp`), then
    a row per other card service (rizzo, ComfyUI with its card or "card auto").
  - **APPS**: services without a card.
  Service rows (`content/ServiceRow.qml`) anchor OPEN and START/STOP to the
  right edge and elide the text; hovering START/STOP previews what else it
  would stop or move. OPEN (or the name) resolves the URL via
  `bin/ai-lab url <name>` (token-gated services like dsh get their one-time
  token appended), opens it with xdg-open, and closes the panel.

## What it runs, reads, and writes

`bin/ai-lab` is a thin wrapper that execs `scripts/ai-lab` from the
ai-lab-quadlets repo (default `~/workspace/github.com/dark5un/ai-lab-quadlets`,
override with `AI_LAB_REPO`). That CLI reads the repo's `services.json`
registry and shells out to:

- `systemctl --user show|start|stop|restart|reset-failed <unit>` — user units only,
  no privileged action anywhere (no sudo/pkexec).
- `curl http://127.0.0.1:<port><health>` — loopback health probes only.
- `scripts/gpu-arbiter.py --dry-run` — the hover previews; plans only, changes nothing.
- `python3` — JSON parsing of the registry and status output.

The plugin reads no files outside the repo's registry and writes nothing
except its own settings through `pluginApi.saveSetting`.

## Settings

| key       | type   | default | description                        |
| --------- | ------ | ------- | ---------------------------------- |
| showCount | toggle | true    | Show the running/total count       |
| pollSec   | int    | 10      | Status poll interval, 3..300 sec   |

## Preview

`assets/preview-widget.png` — the bar glyph with the running/total count.

## Build, check, install

```
ryoku plugin validate .
ryoku plugin add . --bar --yes
```

It lists under **Community** in QS Bar Settings. Publish it only when you want
to share it: `ryoku plugin share ailab`.

## Author

dark5un <dark5un@users.noreply.github.com>: this plugin is community-made (`official` is false).
