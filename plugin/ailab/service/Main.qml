pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// service/Main.qml — the ailab plugin's logic: no UI.
// Polls the ai-lab control-plane CLI (bin/ai-lab -> the ai-lab-quadlets repo's
// scripts/ai-lab, which reads services.json) and exposes the parsed service
// list to the widget and the panel. Toggling a service shells out to
// `ai-lab toggle <name>`, which drives `systemctl --user` on the quadlet unit.
Item {
    id: svc

    // Set by the host after this loads; settings live behind pluginApi.
    property var pluginApi
    readonly property var settings: pluginApi ? pluginApi.pluginSettings : null

    // Parsed rows from `ai-lab status --json`:
    // { name, unit, host_port, bind, tier, boot, state, health }
    property var services: []
    property string lastError: ""
    property string pendingToggle: ""

    readonly property int runningCount: {
        let n = 0;
        for (const s of services) if (s.state === "running") n += 1;
        return n;
    }
    readonly property int totalCount: services.length

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
