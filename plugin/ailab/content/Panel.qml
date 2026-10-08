import QtQuick
import Ryoku.PluginKit.Singletons

// content/Panel.qml — the AI Lab panel: one row per registered service with a
// live state dot, its host port, and a start/stop switch. Clicks call
// service.toggleNamed(name), which shells out to `ai-lab toggle` (systemctl
// --user on the quadlet unit). Strata's GPU variants are one row with an
// OFF / 5090 / 4070TI / BOTH selector (service.switchStrata). llama.cpp is one
// row with the same chips, but 5090 and 4070TI toggle independently (both
// cards may serve at once) and BOTH is exclusive (service.toggleLlama).
// Services whose
// quadlet is not deployed are hidden. The host sizes the card to implicitHeight.
Item {
    id: root

    property var pluginApi
    property string density: "full"
    property real s: 1
    property real widthBudget: 320
    property bool active: false

    readonly property var service: pluginApi ? pluginApi.mainInstance : null
    readonly property var services: service ? service.plainServices : []
    readonly property var strataVariants: service ? service.strataVariants : []
    readonly property var strataLive: service ? service.strataLive : null
    readonly property var llamaVariants: service ? service.llamaVariants : []
    readonly property var llamaLive: service ? service.llamaLive : []

    implicitWidth: root.widthBudget
    implicitHeight: col.implicitHeight + 24 * root.s

    Column {
        id: col
        x: 12 * root.s
        y: 12 * root.s
        width: root.width - 24 * root.s
        spacing: 8 * root.s

        Row {
            spacing: 8 * root.s
            Text {
                text: "AI Lab"
                color: Theme.bright
                font.family: Theme.display
                font.pixelSize: 16 * root.s
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: service ? (service.runningCount + "/" + service.totalCount) : ""
                color: Theme.dim
                font.family: Theme.mono
                font.pixelSize: 12 * root.s
            }
        }

        // Strata: one row, one variant at a time.
        Row {
            visible: root.strataVariants.length > 0
            spacing: 8 * root.s

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8 * root.s
                height: width
                radius: width / 2
                color: root.strataLive ? Theme.accent : Theme.dim
            }

            Column {
                width: root.widthBudget - 226 * root.s
                spacing: 1 * root.s
                Text {
                    text: "strata"
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 13 * root.s
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: root.strataLive
                        ? (root.strataLive.bind + ":" + root.strataLive.host_port + "  " +
                           (root.strataLive.state === "starting" ? "starting"
                            : root.strataLive.health === "down" ? "loading model" : root.strataLive.health))
                        : "off"
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: 10 * root.s
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            // Selector: OFF plus one segment per deployed variant.
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * root.s
                Repeater {
                    model: ["off"].concat(root.strataVariants.map(v => v.variant))
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool live: root.service
                            && root.service.strataVariant === modelData
                        width: (modelData === "4070ti" ? 52 : 40) * root.s
                        height: 20 * root.s
                        radius: Theme.radius
                        color: live ? (modelData === "off" ? Theme.vermDeep : Theme.accent) : Theme.dim

                        Text {
                            anchors.centerIn: parent
                            text: modelData.toUpperCase()
                            color: Theme.cardBot
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.service && !parent.live)
                                root.service.switchStrata(modelData)
                        }
                    }
                }
            }
        }

        // llama.cpp: one row; single-card chips toggle, BOTH is exclusive.
        Row {
            visible: root.llamaVariants.length > 0
            spacing: 8 * root.s

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8 * root.s
                height: width
                radius: width / 2
                color: root.llamaLive.length > 0 ? Theme.accent : Theme.dim
            }

            Column {
                width: root.widthBudget - 226 * root.s
                spacing: 1 * root.s
                Text {
                    text: "llama.cpp"
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 13 * root.s
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: root.llamaLive.length > 0
                        ? root.llamaLive.map(v => ":" + v.host_port + " " +
                              (v.state === "starting" ? "starting" : v.health)).join("  ")
                        : "off"
                    color: Theme.dim
                    font.family: Theme.mono
                    font.pixelSize: 10 * root.s
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * root.s
                Repeater {
                    model: ["off"].concat(root.llamaVariants.map(v => v.variant))
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool live: modelData === "off"
                            ? root.llamaLive.length === 0
                            : root.llamaLive.some(v => v.variant === modelData)
                        width: (modelData === "4070ti" ? 52 : 40) * root.s
                        height: 20 * root.s
                        radius: Theme.radius
                        color: live ? (modelData === "off" ? Theme.vermDeep : Theme.accent) : Theme.dim

                        Text {
                            anchors.centerIn: parent
                            text: modelData.toUpperCase()
                            color: Theme.cardBot
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            // OFF only acts when something runs; a lit card
                            // chip stops that server, an unlit one starts it.
                            onClicked: if (root.service && !(modelData === "off" && parent.live))
                                root.service.toggleLlama(modelData)
                        }
                    }
                }
            }
        }

        Repeater {
            model: root.services

            delegate: Row {
                required property var modelData
                spacing: 8 * root.s

                // State dot: accent when running, dim when stopped.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8 * root.s
                    height: width
                    radius: width / 2
                    color: modelData.state === "running" ? Theme.accent : Theme.dim
                }

                Column {
                    width: root.widthBudget - 170 * root.s
                    spacing: 1 * root.s
                    Text {
                        text: modelData.name
                        color: Theme.bright
                        font.family: Theme.font
                        font.pixelSize: 13 * root.s
                        elide: Text.ElideRight
                        width: parent.width
                        // Click the name to open the service in the browser.
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.service)
                                root.service.launchNamed(modelData.name)
                        }
                    }
                    Text {
                        text: modelData.bind + ":" + modelData.host_port +
                              "  " + modelData.health +
                              (modelData.card ? "  · " + modelData.card : "")
                        color: Theme.dim
                        font.family: Theme.mono
                        font.pixelSize: 10 * root.s
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // Launch: open the service URL in the default browser.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56 * root.s
                    height: 20 * root.s
                    radius: Theme.radius
                    color: modelData.state === "running" ? Theme.accent : Theme.dim

                    Text {
                        anchors.centerIn: parent
                        text: "LAUNCH"
                        color: Theme.cardBot
                        font.family: Theme.font
                        font.pixelSize: 10 * root.s
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.service)
                            root.service.launchNamed(modelData.name)
                    }
                }

                // Start/stop switch.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 46 * root.s
                    height: 20 * root.s
                    radius: Theme.radius
                    color: modelData.state === "running" ? Theme.vermDeep : Theme.accent

                    Text {
                        anchors.centerIn: parent
                        text: modelData.state === "running" ? "STOP" : "START"
                        color: Theme.cardBot
                        font.family: Theme.font
                        font.pixelSize: 10 * root.s
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.service)
                            root.service.toggleNamed(modelData.name)
                    }
                }
            }
        }

        Text {
            visible: service && service.lastError !== ""
            text: service ? service.lastError : ""
            color: Theme.vermDeep
            font.family: Theme.mono
            font.pixelSize: 10 * root.s
            wrapMode: Text.WordWrap
            width: col.width
        }
    }
}
