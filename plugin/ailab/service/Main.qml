pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// service/Main.qml — the ailab plugin's logic: no UI.
// Polls the ai-lab control-plane CLI (bin/ai-lab -> the ai-lab-quadlets repo's
// scripts/ai-lab, which reads services.json) and exposes the parsed service
// list to the widget and the panel. Toggling a service shells out to
// `ai-lab toggle <name>`, which drives `systemctl --user` on the quadlet unit.
// Strata's GPU variants (registry group "strata") are one row with a card
// selector (`ai-lab strata 5090|4070ti|both|off`) and context chips for the
// cards that have them (<card> = 256K, <card>-524k, <card>-1m; strata-both is
// 256K only). The coder group (strata-coder at 256K / 524K / 1M on the 4070 Ti,
// beside a 5090 variant) is a CODER selector (`ai-lab coder 256k|524k|1m|off`);
// the arbiter applies the card rules.
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
                card: live ? live.variant : "auto",
                state: live ? live.state : "stopped",
                health: live ? live.health : "-"
            }));
        }
        // Grafana gets its own row (OPEN button) like the other web apps;
        // the rest of the monitoring group is driven by the MONITORING row.
        const graf = services.find(s => s.installed && s.name === "grafana");
        if (graf) rows.push(graf);
        return rows;
    }

    // The monitoring tier: ON when Prometheus (the anchor) runs; the whole
    // group starts/stops together via `ai-lab start|stop monitoring`.
    readonly property var monitoringRows: services.filter(s => s.installed && s.group === "monitoring")
    readonly property bool monitoringLive: {
        const p = monitoringRows.find(s => s.name === "prometheus");
        return !!p && (p.state === "running" || p.state === "starting");
    }
    function toggleMonitoring() {
        if (monProc.running) return;
        monProc.verb = monitoringLive ? "stop" : "start";
        monProc.running = true;
        const on = !monitoringLive;
        svc.services = svc.services.map(s =>
            s.group === "monitoring"
                ? Object.assign({}, s, { state: on ? "starting" : "stopped", health: "-" })
                : s);
    }
    Process {
        id: monProc
        property string verb: "start"
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  monProc.verb, "monitoring"]
        onExited: (code) => {
            if (code !== 0) svc.lastError = monProc.verb + " monitoring failed (exit " + code + ")";
            svc.refresh();
        }
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
    // A variant's card and context: "4070ti-1m" -> card "4070ti", ctx "1m";
    // no suffix = 256K ("256k").
    function cardOf(v) { return v === "off" ? "off" : v.split("-")[0] }
    function ctxOf(v) { const i = v.indexOf("-"); return v === "off" ? "" : i < 0 ? "256k" : v.slice(i + 1) }
    readonly property string strataCard: cardOf(strataVariant)
    readonly property string strataCtx: ctxOf(strataVariant)
    // The strata variant for a card + context, or "" when it is not deployed.
    function strataFor(card, ctx) {
        const v = ctx === "256k" ? card : card + "-" + ctx;
        return strataVariants.some(s => s.variant === v) ? v : "";
    }
    // The coder group (strata-coder, -524k, -1m): deployed variants, the live
    // one, and its context ("" when off). `coder` is the live row, or the 256K
    // row while off (for the status line); null when none is deployed.
    readonly property var coderVariants:
        services.filter(s => s.installed && s.group === "coder")
    readonly property var coderRow: {
        for (const s of coderVariants)
            if (s.state === "running" || s.state === "starting") return s;
        return null;
    }
    readonly property var coder: coderRow || coderVariants.find(s => s.variant === "coder") || coderVariants[0] || null
    readonly property bool coderLive: coderRow !== null
    readonly property string coderCtx: coderRow ? (coderRow.variant === "coder" ? "256k" : coderRow.variant.slice(6)) : ""

    // The llama-cpp group: deployed variants and the live ones ([] = off).
    readonly property var llamaVariants:
        services.filter(s => s.installed && s.group === "llama-cpp")
    readonly property var llamaLive:
        llamaVariants.filter(s => s.state === "running" || s.state === "starting")

    readonly property int runningCount: {
        let n = (strataLive ? 1 : 0) + (coderLive ? 1 : 0) + (llamaLive.length > 0 ? 1 : 0);
        for (const s of plainServices) if (s.state === "running") n += 1;
        return n;
    }
    readonly property int totalCount:
        plainServices.length + (strataVariants.length > 0 ? 1 : 0) + (coder ? 1 : 0)
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

    // Switch strata to a variant (5090 | 5090-524k | 5090-1m | 4070ti |
    // 4070ti-524k | 4070ti-1m | both) or "off". The start
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

    // Switch the coder to a context (256k | 524k | 1m) or "off", like strata.
    property string pendingCoder: ""
    function switchCoder(ctx) {
        if (coderProc.running) return;
        svc.pendingCoder = ctx;
        coderProc.running = true;
        const want = ctx === "off" ? "" : ctx === "256k" ? "coder" : "coder-" + ctx;
        svc.services = svc.services.map(s =>
            s.group === "coder"
                ? Object.assign({}, s, { state: s.variant === want ? "starting" : "stopped", health: "-" })
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

    // Health in words: "up (200)" -> "ready", "down" -> "loading model".
    function healthText(r) {
        if (!r) return "off";
        if (r.state === "starting") return "starting";
        if (r.state !== "running") return "stopped";
        if (r.health === "down") return "loading model";
        const m = String(r.health).match(/up \((\d+)\)/);
        if (m) return m[1] === "200" ? "ready" : "http " + m[1];
        return r.health;
    }

    // Consequence preview for the panel's hover hint: the arbiter's plan for
    // an action (`ai-lab ... --dry-run`), condensed to "stops a, b · starts c".
    property string previewKey: ""
    property string previewText: ""
    property var previewQueued: null      // [key, argv] waiting for the running dry-run
    // Pointer left a control: clear the preview only if it is still that
    // control's (moving straight to another row can deliver the old row's
    // exit after the new row's enter, which used to blank the new preview).
    function unpreview(prefix) {
        if (svc.previewKey.startsWith(prefix)) svc.preview("", null);
    }
    function preview(key, argv) {
        svc.previewKey = key;
        svc.previewText = "";
        if (key === "" || !argv) return;
        if (previewProc.running) { svc.previewQueued = [key, argv]; return; }
        previewProc.forKey = key;
        previewProc.argv = argv;
        previewProc.running = true;
    }
    Process {
        id: previewProc
        property var argv: []
        property string forKey: ""
        property string out: ""
        stdout: StdioCollector { onStreamFinished: previewProc.out += this.text }
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab"].concat(previewProc.argv, ["--dry-run"])
        onExited: (code) => {
            const q = svc.previewQueued;
            svc.previewQueued = null;
            if (previewProc.forKey !== svc.previewKey) {   // the pointer moved on
                previewProc.out = "";
                if (q && q[0] === svc.previewKey) svc.preview(q[0], q[1]);
                return;
            }
            const stops = [], starts = [];
            for (const line of previewProc.out.split("\n")) {
                const m = line.match(/would (stop|start): (\S+)/);
                // "strata-4070ti-1m" -> "4070ti-1m", "strata-coder-524k" -> "coder-524k":
                // the line sits under the STRATA controls, and must fit one row.
                if (m) (m[1] === "stop" ? stops : starts).push(m[2].replace(/^strata-/, ""));
            }
            previewProc.out = "";
            const parts = [];
            if (starts.length) parts.push("starts " + starts.join(", "));
            if (stops.length) parts.push("stops " + stops.join(", "));
            svc.previewText = parts.length ? parts.join("  ·  ") : "nothing to change";
        }
    }

    Process {
        id: coderProc
        command: [(svc.pluginApi ? svc.pluginApi.pluginDir : "") + "/bin/ai-lab",
                  "coder", svc.pendingCoder]
        onExited: (code) => {
            if (code !== 0) svc.lastError = "coder " + svc.pendingCoder + " failed (exit " + code + ")";
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
