import QtQuick
import Ryoku.PluginKit.Singletons

// content/Panel.qml — the AI Lab panel: one row per registered service with a
// live state dot, its host port, and a start/stop switch. Clicks call
// service.toggleNamed(name), which shells out to `ai-lab toggle` (systemctl
// --user on the quadlet unit). The host sizes the card to implicitHeight.
Item {
    id: root

    property var pluginApi
    property string density: "full"
    property real s: 1
    property real widthBudget: 320
    property bool active: false

    readonly property var service: pluginApi ? pluginApi.mainInstance : null
    readonly property var services: service ? service.services : []

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
                    width: root.widthBudget - 120 * root.s
                    spacing: 1 * root.s
                    Text {
                        text: modelData.name
                        color: Theme.bright
                        font.family: Theme.font
                        font.pixelSize: 13 * root.s
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Text {
                        text: modelData.bind + ":" + modelData.host_port +
                              "  " + modelData.health
                        color: Theme.dim
                        font.family: Theme.mono
                        font.pixelSize: 10 * root.s
                        elide: Text.ElideRight
                        width: parent.width
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
