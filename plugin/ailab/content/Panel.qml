import QtQuick
import Ryoku.PluginKit
import Ryoku.PluginKit.Singletons

// content/Panel.qml — the AI Lab panel, in three sections:
//
//   STRATA        status lines (main model, coder), then one labelled control
//                 per decision:
//                   CARD     OFF | 5090 | 4070 TI | BOTH   (one variant at a time;
//                                                         a card keeps the context)
//                   CONTEXT  256K | 524K | 1M              (the 5090's or the 4070
//                                                         Ti's variants; from off
//                                                         or BOTH it picks the 5090)
//                   CODER    OFF | 256K | 524K | 1M        (the coder on the 4070 Ti,
//                                                         beside a 5090 variant)
//                 and a hint line that previews what a hovered choice starts and
//                 stops (the arbiter's --dry-run).
//   GPU SERVICES  llama.cpp (OFF | 5090 | 4070 TI | BOTH; the single cards
//                 toggle independently), then the other services that use a card.
//   APPS          services without a card.
//
// Every control is a Segmented (content/Segmented.qml): its segments share the
// row's width, so options never run off the card. Service rows
// (content/ServiceRow.qml) anchor their buttons to the right edge and elide
// the text column, for the same reason. The host adds the card's 12 px margin.
Item {
    id: root

    property var pluginApi
    property string density: "full"
    property real s: 1
    property real widthBudget: 356
    property bool active: false

    readonly property var service: pluginApi ? pluginApi.mainInstance : null
    readonly property var strataVariants: service ? service.strataVariants : []
    readonly property var strataLive: service ? service.strataLive : null
    readonly property string strataVariant: service ? service.strataVariant : "off"
    readonly property string strataCard: service ? service.strataCard : "off"
    readonly property string strataCtx: service ? service.strataCtx : ""
    readonly property var coder: service ? service.coder : null
    readonly property bool coderLive: service ? service.coderLive : false
    readonly property string coderCtx: service ? service.coderCtx : ""
    // The CODER row's live choice: "off" or the running coder's context.
    readonly property string coderChoice: coderLive ? coderCtx : "off"
    readonly property var coderVariants: service ? service.coderVariants : []
    // The card the CONTEXT row applies to: strata's card when it has context
    // variants, else the 5090 (from off or BOTH a context pick means the 5090).
    readonly property string ctxCard: (strataCard === "5090" || strataCard === "4070ti") ? strataCard : "5090"
    readonly property var llamaVariants: service ? service.llamaVariants : []
    readonly property var llamaLive: service ? service.llamaLive : []
    // Plain rows split by whether the service needs a card.
    readonly property var gpuRows: service ? service.plainServices.filter(r => r.gpu || r.name === "comfyui") : []
    readonly property var appRows: service ? service.plainServices.filter(r => !r.gpu && r.name !== "comfyui") : []
    readonly property bool monitoringLive: service ? service.monitoringLive : false
    readonly property int monitoringCount: service ? service.monitoringRows.length : 0
    readonly property string previewKey: service ? service.previewKey : ""
    readonly property string previewText: service ? service.previewText : ""

    readonly property real labelW: 64

    function has(variant) { return strataVariants.some(v => v.variant === variant) }
    function stateText(r) { return service ? service.healthText(r) : "" }
    // Strata status lines are tight (card, context, port): "loading model" -> "loading".
    function strataState(r) { const x = stateText(r); return x === "loading model" ? "loading" : x }
    function ctxLabel(c) { return c === "256k" ? "256K" : c === "524k" ? "524K" : c === "1m" ? "1M" : "" }
    function cardLabel(c) { return c === "4070ti" ? "4070 Ti" : c === "both" ? "both cards" : c }
    // The variant for a card that keeps the live context when it can.
    function variantFor(card, ctx) {
        if (!service || card === "off" || card === "both") return card;
        return service.strataFor(card, ctx || "256k") || card;
    }
    // Hover on a control row: key "" = the pointer left this row (prefix).
    function hover(prefix, key, argv) {
        if (!service) return;
        if (key === "") service.unpreview(prefix); else service.preview(prefix + key, argv);
    }

    implicitWidth: root.widthBudget
    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: root.widthBudget
        spacing: 8 * root.s

        // Header: title and running/total count.
        Item {
            width: col.width
            height: 22 * root.s
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "AI Lab"
                color: Theme.bright
                font.family: Theme.display
                font.pixelSize: 16 * root.s
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.service ? (root.service.runningCount + " / " + root.service.totalCount + " running") : ""
                color: Theme.dim
                font.family: Theme.mono
                font.pixelSize: 10 * root.s
            }
        }

        // ---- STRATA -----------------------------------------------------------
        MicroLabel { label: "STRATA"; s: root.s; visible: root.strataVariants.length > 0 }

        Column {
            visible: root.strataVariants.length > 0
            width: col.width
            spacing: 4 * root.s

            // Status: one line per instance, with OPEN in the same right-hand
            // column as the service rows (the instance's web app: chat,
            // Monitor tab, settings). OPEN is live only once the model is ready.
            Repeater {
                model: [
                    { name: root.strataLive ? root.strataLive.name : "", show: true,
                      row: root.strataLive,
                      text: root.strataLive !== null
                          ? ("main   " + root.cardLabel(root.strataCard)
                             + (root.strataCard === "both" ? "" : " · " + root.ctxLabel(root.strataCtx))
                             + "  :" + root.strataLive.host_port + "  " + root.strataState(root.strataLive))
                          : "main   off" },
                    { name: root.coder ? root.coder.name : "", show: root.coder !== null,
                      row: root.coderLive ? root.coder : null,
                      text: root.coderLive && root.coder
                          ? ("coder  4070 Ti · " + root.ctxLabel(root.coderCtx) + "  :" + root.coder.host_port
                             + "  " + root.strataState(root.coder))
                          : "coder  off" }
                ]
                delegate: Item {
                    id: statusRow
                    required property var modelData
                    readonly property bool live: modelData.row !== null && modelData.row !== undefined
                    readonly property bool ready: live && modelData.row.state === "running"
                                                  && String(modelData.row.health).startsWith("up")
                    visible: modelData.show
                    width: col.width
                    height: visible ? 24 * root.s : 0

                    Rectangle {
                        id: sdot
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6 * root.s; height: width; radius: width / 2
                        color: statusRow.live ? Theme.accent : Theme.hair
                    }
                    Text {
                        anchors.left: sdot.right
                        anchors.leftMargin: 6 * root.s
                        anchors.right: open.left
                        anchors.rightMargin: 8 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        text: statusRow.modelData.text
                        color: statusRow.live ? Theme.bright : Theme.dim
                        font.family: Theme.mono
                        font.pixelSize: 10 * root.s
                        elide: Text.ElideRight
                    }
                    // Same size and place as ServiceRow's OPEN (right edge minus
                    // the START/STOP column), so the OPEN buttons line up.
                    Rectangle {
                        id: open
                        anchors.right: parent.right
                        anchors.rightMargin: 56 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        width: 50 * root.s; height: 22 * root.s
                        radius: Theme.radius
                        color: "transparent"
                        border.width: 1
                        border.color: statusRow.ready ? Theme.border : Theme.hair
                        Text {
                            anchors.centerIn: parent
                            text: "OPEN"
                            color: statusRow.ready ? Theme.bright : Theme.faint
                            opacity: statusRow.ready ? 1 : 0.45
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: statusRow.ready
                            cursorShape: statusRow.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (root.service) root.service.launchNamed(statusRow.modelData.name)
                        }
                    }
                }
            }

            Item { width: 1; height: 2 * root.s }

            Segmented {
                width: col.width
                s: root.s
                label: "CARD"
                labelWidth: root.labelW
                options: [{ key: "off", label: "OFF", on: root.strataCard === "off" }]
                    .concat(["5090", "4070ti", "both"].filter(v => root.has(v)).map(v => ({
                        key: v,
                        label: v === "4070ti" ? "4070 TI" : v.toUpperCase(),
                        on: root.strataCard === v
                    })))
                onPicked: (key) => {
                    if (!root.service || key === root.strataCard) return;
                    root.service.switchStrata(root.variantFor(key, root.strataCtx));   // keeps the context
                }
                onHovered: (key) => root.hover("strata:card-", key,
                                               key === "" || key === root.strataCard ? null
                                                   : ["strata", root.variantFor(key, root.strataCtx)])
            }

            Segmented {
                visible: root.strataVariants.some(v => v.variant.includes("-"))
                width: col.width
                s: root.s
                label: "CONTEXT"
                labelWidth: root.labelW
                options: ["256k", "524k", "1m"].filter(c => root.service && root.service.strataFor(root.ctxCard, c) !== "")
                    .map(c => ({
                        key: c, label: root.ctxLabel(c),
                        on: root.strataCard === root.ctxCard && root.strataCtx === c
                    }))
                onPicked: (key) => {
                    const v = root.service ? root.service.strataFor(root.ctxCard, key) : "";
                    if (v !== "" && v !== root.strataVariant) root.service.switchStrata(v);
                }
                onHovered: (key) => {
                    const v = key === "" || !root.service ? "" : root.service.strataFor(root.ctxCard, key);
                    root.hover("strata:ctx-", key,
                               v === "" || v === root.strataVariant ? null : ["strata", v]);
                }
            }

            Segmented {
                visible: root.coder !== null
                width: col.width
                s: root.s
                label: "CODER"
                labelWidth: root.labelW
                // OFF, then the deployed contexts (strata-coder = 256K, -524k, -1m).
                options: [{ key: "off", label: "OFF", on: !root.coderLive }]
                    .concat(["256k", "524k", "1m"]
                        .filter(c => root.coderVariants.some(v => v.variant === (c === "256k" ? "coder" : "coder-" + c)))
                        .map(c => ({ key: c, label: root.ctxLabel(c), on: root.coderLive && root.coderCtx === c })))
                onPicked: (key) => { if (root.service && key !== root.coderChoice) root.service.switchCoder(key) }
                onHovered: (key) => root.hover("strata:coder-", key,
                                               key === "" || key === root.coderChoice ? null : ["coder", key])
            }

            // Consequence preview: fixed height so the panel does not jump.
            // Aligned with the segments; a long plan (a duo switch names three
            // units) also takes the label column instead of eliding.
            Text {
                id: strataHint
                width: col.width
                height: 14 * root.s
                leftPadding: hintMetrics.advanceWidth + root.labelW * root.s <= width ? root.labelW * root.s : 0
                TextMetrics { id: hintMetrics; font: strataHint.font; text: strataHint.text }
                text: root.previewKey.startsWith("strata:") && root.previewText !== "" ? "→ " + root.previewText : ""
                color: Theme.gold
                font.family: Theme.mono
                font.pixelSize: 10 * root.s
                elide: Text.ElideRight
            }
        }

        // ---- GPU SERVICES -----------------------------------------------------
        MicroLabel { label: "GPU SERVICES"; s: root.s; visible: root.llamaVariants.length > 0 || root.gpuRows.length > 0 }

        Column {
            width: col.width
            spacing: 4 * root.s

            Segmented {
                visible: root.llamaVariants.length > 0
                width: col.width
                s: root.s
                label: "LLAMA"
                labelWidth: root.labelW
                options: [{ key: "off", label: "OFF", on: root.llamaLive.length === 0 }]
                    .concat(root.llamaVariants.map(v => ({
                        key: v.variant,
                        label: v.variant === "4070ti" ? "4070 TI" : v.variant.toUpperCase(),
                        on: root.llamaLive.some(l => l.variant === v.variant)
                    })))
                onPicked: (key) => {
                    if (!root.service || (key === "off" && root.llamaLive.length === 0)) return;
                    root.service.toggleLlama(key);
                }
                onHovered: (key) => root.hover("llama:", key,
                                               key === "" || (key === "off" && root.llamaLive.length === 0) ? null
                                                   : key === "off" ? ["stop", "llama-cpp"]
                                                   : ["toggle", "llama-cpp-" + key])
            }
            // llama status, or the preview while a llama chip is hovered.
            Text {
                visible: root.llamaVariants.length > 0
                width: col.width
                height: 14 * root.s
                leftPadding: root.labelW * root.s
                readonly property bool previewing: root.previewKey.startsWith("llama:") && root.previewText !== ""
                text: previewing ? "→ " + root.previewText
                    : root.llamaLive.map(v => (v.variant === "4070ti" ? "4070 Ti" : v.variant)
                                             + " :" + v.host_port + " " + root.stateText(v)).join("    ")
                color: previewing ? Theme.gold : Theme.dim
                font.family: Theme.mono
                font.pixelSize: 10 * root.s
                elide: Text.ElideRight
            }

            Repeater {
                model: root.gpuRows
                delegate: ServiceRow {
                    required property var modelData
                    width: col.width
                    s: root.s
                    row: modelData
                    service: root.service
                }
            }
        }

        // ---- APPS -------------------------------------------------------------
        MicroLabel { label: "APPS"; s: root.s; visible: root.appRows.length > 0 }

        Column {
            width: col.width
            spacing: 4 * root.s
            Repeater {
                model: root.appRows
                delegate: ServiceRow {
                    required property var modelData
                    width: col.width
                    s: root.s
                    row: modelData
                    service: root.service
                }
            }
        }

        // ---- MONITORING -------------------------------------------------------
        MicroLabel { label: "MONITORING"; s: root.s; visible: root.monitoringCount > 0 }

        Column {
            width: col.width
            spacing: 4 * root.s
            Segmented {
                visible: root.monitoringCount > 0
                width: col.width
                s: root.s
                label: "STACK"
                labelWidth: root.labelW
                options: [
                    { key: "off", label: "OFF", on: !root.monitoringLive },
                    { key: "on",  label: "ON",  on: root.monitoringLive }
                ]
                onPicked: (key) => {
                    if (!root.service) return;
                    if ((key === "on") !== root.monitoringLive) root.service.toggleMonitoring();
                }
            }
        }

        Text {
            visible: root.service !== null && root.service.lastError !== ""
            text: root.service ? root.service.lastError : ""
            color: Theme.vermLit
            font.family: Theme.mono
            font.pixelSize: 10 * root.s
            wrapMode: Text.WordWrap
            width: col.width
        }
    }
}
