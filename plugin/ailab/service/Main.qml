pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// service/Main.qml — the ailab plugin's logic: no UI.
// Polls the ai-lab control-plane CLI (bin/ai-lab -> the ai-lab-quadlets repo's
// scripts/ai-lab, which reads services.json) and exposes the parsed service
// list to the widget and the panel. Toggling a service shells out to
// `ai-lab toggle <name>`, which drives `systemctl --user` on the quadlet unit.
// Strata's three GPU variants (registry group "strata") are one row with a
// selector: `ai-lab strata 5090|4070ti|both|off` (Conflicts= in the units
// stops the running variant, and rizzo when the 4070 Ti is taken).
// llama.cpp's three servers (group "llama-cpp") are one row too, but its
// 5090 / 4070 Ti chips are independent toggles (both cards may serve at
// once); BOTH is exclusive and OFF stops the group. Every start goes through
// `ai-lab toggle`, so scripts/gpu-arbiter.py applies the GPU rules.
Item {
    id: svc

    // Set by the host after this loads; settings live behind pluginApi.
    property var pluginApi
    readonly property var settings: pluginApi ? pluginApi.pluginSettings : null

    // Parsed rows from `ai-lab status --json`:
    // { name, unit, host_port, bind, tier, boot, group, variant, installed,
    //   state, health }
    property var services: []
    property string lastError: ""
    property string pendingToggle: ""
    property string pendingVariant: ""

    // Rows for the plain START/STOP list: services deployed on this host
    // (registry entries whose quadlet is not installed are hidden), plus one
    // synthesized row for ComfyUI, whose card the arbiter picks (the variant
    // is shown as `card`). Strata has its own selector row.
    readonly property var plainServices: {
        const rows = services.filter(s => s.installed && !s.group);
        const comfy = services.filter(s => s.installed && s.group === "comfyui");
        if (comfy.length > 0) {
            const live = comfy.find(s => s.state === "running" || s.state === "starting");
            const base = live || comfy[0];
            rows.push(Object.assign({}, base, {
                name: "comfyui",
                card: live ? live.variant : "",
                state: live ? live.state : "stopped",
                health: live ? live.health : "-"
            }));
        }
        return rows;
    }

    // The strata group: its deployed variants and the live one ("off" if none).
    readonly property var strataVariants:
        services.filter(s => s.installed && s.group === "strata")
    readonly property var strataLive: {
        for (const s of strataVariants)
            if (s.state === "running" || s.state === "starting") return s;
        return null;
    }
    readonly property string strataVariant: strataLive ? strataLive.variant : "off"

    // The llama-cpp group: deployed variants and the live ones ([] = off).
    readonly property var llamaVariants:
        services.filter(s => s.installed && s.group === "llama-cpp")
    readonly property var llamaLive:
        llamaVariants.filter(s => s.state === "running" || s.state === "starting")

    readonly property int runningCount: {
        let n = (strataLive ? 1 : 0) + (llamaLive.length > 0 ? 1 : 0);
        for (const s of plainServices) if (s.state === "running") n += 1;
        return n;
    }
    readonly property int totalCount:
        plainServices.length + (strataVariants.length > 0 ? 1 : 0)
        + (llamaVariants.length > 0 ? 1 : 0)

    readonly property int pollMs: {
        const sec = svc.settings ? (svc.settings.pollSec ?? 10) : 10;
        return Math.max(3, sec) * 1000;
    }

    function refresh() {
        if (pollProc.running) return;
        pollProc.running = true;
    }

    // Toggle one service; the next poll reflects the real state.
    function toggleNamed(name) {
        svc.pendingToggle = name;
        actProc.running = true;
        // Optimistic flip so the panel feels instant; the poll corrects it.
        svc.services = svc.services.map(s =>
            s.name === name
                ? Object.assign({}, s, {
                    state: s.state === "running" ? "stopped" : "running",
                    health: s.state === "running" ? "down" : "up"
                })
                : s);
    }

    // Switch strata to a variant (5090 | 4070ti | both) or "off". The start
    // blocks until the old variant has stopped, so it runs in its own process;
    // the poll shows the new state.
    function switchStrata(variant) {
        if (strataProc.running) return;
        svc.pendingVariant = variant;
        strataProc.running = true;
        // Optimistic: mark the chosen variant starting, the others stopped.
        svc.services = svc.services.map(s =>
            s.group === "strata"
                ? Object.assign({}, s, {
                    state: s.variant === variant ? "starting" : "stopped",
                    health: "-"
                })
                : s);
    }

    // llama.cpp chips: "off" stops the group; a variant toggles that server
    // (the arbiter stops llama-cpp-both before a single card starts, and the
    // single cards before BOTH starts).
    function toggleLlama(variant) {
        if (llamaProc.running) return;
        const stopping = variant === "off"
            || llamaLive.some(s => s.variant === variant);
        llamaProc.verb = variant === "off" ? "stop" : "toggle";
        llamaProc.target = variant === "off" ? "llama-cpp" : "llama-cpp-" + variant;
        llamaProc.running = true;
        // Optimistic: reflect the request; the poll corrects it.
        svc.services = svc.services.map(s => {
            if (s.group !== "llama-cpp") return s;
            let on = s.state === "running" || s.state === "starting";
            if (variant === "off") on = false;
            else if (s.variant === variant) on = !stopping;
            else if (!stopping && (variant === "both" || s.variant === "both")) on = false;
            return Object.assign({}, s, { state: on ? "starting" : "stopped", health: "-" });
        });
    }

    Process {
        id: llamaProc
        property string verb: "toggle"
        property string target: ""
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  llamaProc.verb, llamaProc.target]
        onExited: (code) => {
            if (code !== 0) svc.lastError = llamaProc.verb + " " + llamaProc.target + " failed (exit " + code + ")";
            svc.refresh();
        }
    }

    Process {
        id: strataProc
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  "strata", svc.pendingVariant]
        onExited: (code) => {
            if (code !== 0) svc.lastError = "strata " + svc.pendingVariant + " failed (exit " + code + ")";
            svc.refresh();
        }
    }

    // Open a service's web surface in the default browser, then close the
    // panel so focus lands on the browser. The URL comes from `ai-lab url`,
    // which appends the one-time token for token-gated services (dsh).
    property string pendingLaunch: ""
    function launchNamed(name) {
        svc.pendingLaunch = name;
        urlProc.running = true;
        if (svc.pluginApi) svc.pluginApi.closePanel();
    }

    Process {
        id: urlProc
        property string out: ""
        stdout: StdioCollector { onStreamFinished: urlProc.out += this.text }
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  "url", svc.pendingLaunch]
        onExited: (code) => {
            const url = urlProc.out.trim();
            urlProc.out = "";
            if (code === 0 && url !== "")
                Quickshell.execDetached(["xdg-open", url]);
            else
                svc.lastError = "could not resolve URL for " + svc.pendingLaunch;
        }
    }

    Process {
        id: pollProc
        property string out: ""
        stdout: StdioCollector { onStreamFinished: pollProc.out += this.text }
        stderr: StdioCollector { onStreamFinished: svc.lastError += this.text }
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  "status", "--json"]
        onExited: (code) => {
            if (code === 0) {
                try {
                    svc.services = JSON.parse(pollProc.out);
                    svc.lastError = "";
                } catch (e) {
                    svc.lastError = "bad JSON from ai-lab status";
                }
            } else {
                svc.lastError = "ai-lab status failed (exit " + code + ")";
            }
            pollProc.out = "";
        }
    }

    Process {
        id: actProc
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  "toggle", svc.pendingToggle]
        onExited: (code) => {
            if (code !== 0) svc.lastError = "toggle failed (exit " + code + ")";
            svc.refresh();
        }
    }

    Timer {
        interval: svc.pollMs
        running: true
        repeat: true
        onTriggered: svc.refresh()
    }

    Component.onCompleted: svc.refresh()
}
