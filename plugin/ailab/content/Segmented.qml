import QtQuick
import Ryoku.PluginKit.Singletons

// content/Segmented.qml — a labelled segmented control that always fits its
// width: the segments share what is left after the label column equally, so
// adding an option shrinks them instead of pushing one off the card.
//
//   options:  [{ key, label, on, enabled, hint }]
//     on       lit (the live choice; several may be lit for toggles)
//     enabled  false = shown dimmed, not clickable (hint says why)
//     hint     shown under the control while hovered (consequence preview)
//   signals:  picked(key), hovered(key) ("" when the pointer leaves)
Item {
    id: seg

    property string label: ""
    property real labelWidth: 64
    property var options: []
    property real s: 1

    signal picked(string key)
    signal hovered(string key)

    implicitHeight: 22 * s

    Text {
        id: lab
        visible: seg.label !== ""
        width: seg.label !== "" ? seg.labelWidth * seg.s : 0
        anchors.verticalCenter: parent.verticalCenter
        text: seg.label
        color: Theme.faint
        font.family: Theme.mono
        font.pixelSize: 10 * seg.s
        font.letterSpacing: 1.2 * seg.s
        elide: Text.ElideRight
    }

    Row {
        id: strip
        x: lab.width
        width: seg.width - lab.width
        height: parent.height
        spacing: 2 * seg.s

        Repeater {
            model: seg.options
            delegate: Rectangle {
                id: chip
                required property var modelData
                readonly property bool on: modelData.on === true
                readonly property bool enabled: modelData.enabled !== false
                width: (strip.width - strip.spacing * Math.max(0, seg.options.length - 1)) / Math.max(1, seg.options.length)
                height: strip.height
                radius: Theme.radius
                color: on ? Theme.accent
                     : !enabled ? "transparent"
                     : mouse.containsMouse ? Theme.hair : Theme.tileBg
                border.width: 1
                border.color: on ? Theme.accent : enabled ? Theme.border : Theme.hair

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 4 * seg.s
                    horizontalAlignment: Text.AlignHCenter
                    text: chip.modelData.label
                    color: chip.on ? Theme.cardBot : chip.enabled ? Theme.bright : Theme.faint
                    opacity: chip.enabled || chip.on ? 1 : 0.45
                    font.family: Theme.font
                    font.pixelSize: 10 * seg.s
                    font.weight: chip.on ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: chip.enabled && !chip.on ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onEntered: seg.hovered(chip.modelData.key)
                    onExited: seg.hovered("")
                    onClicked: if (chip.enabled) seg.picked(chip.modelData.key)
                }
            }
        }
    }
}
