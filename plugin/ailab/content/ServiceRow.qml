import QtQuick
import Ryoku.PluginKit.Singletons

// content/ServiceRow.qml — one service: state dot, name (click = open in the
// browser), "port · health · card" line, then OPEN and START/STOP anchored to
// the right edge. The text column takes whatever is left and elides, so the
// buttons never leave the card.
Item {
    id: sr

    property var row: ({})
    property var service: null
    property real s: 1

    readonly property bool running: row.state === "running" || row.state === "starting"
    readonly property string card: row.card ? row.card : row.gpu ? row.gpu : ""
    // While START/STOP is hovered, the sub-line previews what the arbiter
    // would do (other services it stops or moves).
    readonly property bool previewing: service !== null && service.previewKey === "row:" + row.name
                                       && service.previewText !== ""

    implicitHeight: 30 * s

    Rectangle {
        id: dot
        anchors.verticalCenter: parent.verticalCenter
        width: 6 * sr.s; height: width; radius: width / 2
        color: sr.running ? Theme.accent : Theme.hair
    }

    Column {
        anchors.left: dot.right
        anchors.leftMargin: 8 * sr.s
        anchors.right: buttons.left
        anchors.rightMargin: 8 * sr.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1 * sr.s

        Text {
            width: parent.width
            text: sr.row.name || ""
            color: Theme.bright
            font.family: Theme.font
            font.pixelSize: 13 * sr.s
            elide: Text.ElideRight
            MouseArea {
                anchors.fill: parent
                enabled: sr.running
                cursorShape: sr.running ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (sr.service) sr.service.launchNamed(sr.row.name)
            }
        }
        Text {
            width: parent.width
            text: sr.previewing ? "→ " + sr.service.previewText
                : ":" + sr.row.host_port
                  + (sr.running && sr.service ? "  " + sr.service.healthText(sr.row) : "")
                  + (sr.card ? "  · " + (sr.card === "4070ti" ? "4070 Ti" : sr.card === "auto" ? "card auto" : sr.card) : "")
            color: sr.previewing ? Theme.gold : Theme.dim
            font.family: Theme.mono
            font.pixelSize: 10 * sr.s
            elide: Text.ElideRight
        }
    }

    Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4 * sr.s

        // OPEN: only meaningful while it runs.
        Rectangle {
            width: 50 * sr.s; height: 22 * sr.s
            radius: Theme.radius
            color: "transparent"
            border.width: 1
            border.color: sr.running ? Theme.border : Theme.hair
            Text {
                anchors.centerIn: parent
                text: "OPEN"
                color: sr.running ? Theme.bright : Theme.faint
                opacity: sr.running ? 1 : 0.45
                font.family: Theme.font
                font.pixelSize: 10 * sr.s
            }
            MouseArea {
                anchors.fill: parent
                enabled: sr.running
                cursorShape: sr.running ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (sr.service) sr.service.launchNamed(sr.row.name)
            }
        }

        // START / STOP: filled accent = action that starts, outlined = stop.
        Rectangle {
            width: 52 * sr.s; height: 22 * sr.s
            radius: Theme.radius
            color: sr.running ? "transparent" : Theme.accent
            border.width: 1
            border.color: sr.running ? Theme.vermDeep : Theme.accent
            Text {
                anchors.centerIn: parent
                text: sr.running ? "STOP" : "START"
                color: sr.running ? Theme.bright : Theme.cardBot
                font.family: Theme.font
                font.pixelSize: 10 * sr.s
                font.weight: Font.DemiBold
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: if (sr.service) sr.service.preview("row:" + sr.row.name, ["toggle", sr.row.name])
                onExited: if (sr.service) sr.service.preview("", null)
                onClicked: if (sr.service) sr.service.toggleNamed(sr.row.name)
            }
        }
    }
}
