# AI Lab

A Ryoku shell plugin (`ailab`) that puts the ai-lab-quadlets stack on the QS
Bar: a glyph with a running/total count, and a panel listing every registered
service with a live state dot, its host port, health, and a START/STOP switch.

## What it does

- **Service** (`service/Main.qml`): polls `bin/ai-lab status --json` on a
  timer (default 10 s) and exposes the parsed rows to both views.
- **Widget** (`content/Widget.qml`): the bar glyph plus the running/total
  count. A left click only opens the panel; it never changes state.
- **Panel** (`content/Panel.qml`): one row per service; clicking START/STOP
  calls `bin/ai-lab toggle <name>`.

## What it runs, reads, and writes

`bin/ai-lab` is a thin wrapper that execs `scripts/ai-lab` from the
ai-lab-quadlets repo (default `~/workspace/github.com/dark5un/ai-lab-quadlets`,
override with `AI_LAB_REPO`). That CLI reads the repo's `services.json`
registry and shells out to:

- `systemctl --user is-active|start|stop|restart <unit>` — user units only,
  no privileged action anywhere (no sudo/pkexec).
- `curl http://127.0.0.1:<port><health>` — loopback health probes only.
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
