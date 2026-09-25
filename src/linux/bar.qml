// Agent Belt in Omarchy's bar: the belt every platform shows (the macOS menu
// bar icon, the Windows tray icon) and the count of agent sessions on every
// machine, from `agb waybar`. A click opens the agent menu. Written by
// `agb install` (src/linux/desktop.zig), which puts agb's path in @AGB@.
import QtQuick
import Quickshell.Io

Item {
    id: root
    property var bar
    property string moduleName
    property var settings
    property int count: 0
    property string tip: "Agent Belt"
    readonly property bool tooltipHovered: hover.hovered
    readonly property color ink: bar ? bar.foreground : "white"

    implicitWidth: row.implicitWidth + 12
    implicitHeight: bar ? bar.barSize : 26
    onInkChanged: belt.requestPaint()

    Process {
        id: poll
        command: ["@AGB@", "waybar"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const state = JSON.parse(text)
                    root.count = parseInt(state.text) || 0
                    root.tip = state.tooltip || "Agent Belt"
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: 15000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!poll.running) poll.running = true
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        // mk_belt_icon (src/status_item.m): a strap behind a rounded buckle
        // with the lamp in its middle.
        Canvas {
            id: belt
            width: 22; height: 16
            anchors.verticalCenter: parent.verticalCenter
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.fillStyle = root.ink
                ctx.strokeStyle = root.ink
                ctx.beginPath()
                ctx.roundedRect(0.5, 6.4, 4.3, 3.2, 1.6, 1.6)
                ctx.roundedRect(17.2, 6.4, 4.3, 3.2, 1.6, 1.6)
                ctx.fill()
                ctx.lineWidth = 1.7
                ctx.beginPath()
                ctx.roundedRect(6, 1.5, 10, 13, 3.4, 3.4)
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(11, 8, 1.5, 0, 2 * Math.PI)
                ctx.fill()
            }
        }

        Text {
            visible: root.count > 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.count
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: 12
        }
    }

    HoverHandler {
        id: hover
        onHoveredChanged: if (root.bar) hovered ? root.bar.showTooltip(root, root.tip) : root.bar.hideTooltip(root)
    }

    MouseArea {
        anchors.fill: parent
        onClicked: if (root.bar) root.bar.run(root.bar.shellQuote("@AGB@") + " menu")
    }
}
