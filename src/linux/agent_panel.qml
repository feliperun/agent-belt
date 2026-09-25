// Agent Belt's create-agent panel on Linux, the Mac panel's twin
// (src/create_panel.m): the dictation overlay's sibling, centered, with the
// words as they stream in, what was understood (agent, machine, repo) as chips
// to correct, the session's name and a one-line summary.
// agb writes the state as JSON to $AGB_PANEL_STATE; the panel writes edits,
// choices and actions to $AGB_PANEL_CMD (src/linux/agent_panel.zig).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property var st: ({})
    property var plan: null
    property var summary: null
    property int seq: 0
    property bool syncing: false
    property string menuKey: ""
    property real level: 0
    property real phase: 0
    property real lastTick: Date.now() / 1000

    function ink(a) { return Qt.rgba(184 / 255, 201 / 255, 245 / 255, a) }
    function css(a) { return "rgba(184, 201, 245, " + a + ")" }

    function send(extra) {
        root.seq += 1
        const cmd = { seq: root.seq, text: edit.text }
        for (const k in extra) cmd[k] = extra[k]
        cmdFile.setText(JSON.stringify(cmd))
    }

    // What a chip shows: the choice, else the detection. Confidence 0 is a
    // default (not said), shown dimmer; below 0.6 Jev is unsure, marked "?".
    function chip(key) {
        const fixed = root.st.fixed ? root.st.fixed[key] : null
        const chosen = fixed !== null && fixed !== undefined
        const value = chosen ? fixed : (root.plan ? root.plan[key] : null)
        const confidence = chosen ? 1 : (root.plan ? root.plan[key + "_confidence"] || 0 : 0)
        const missing = !value
        const unsure = !missing && confidence > 0 && confidence < 0.6
        const shown = missing ? (key === "repo" ? "none" : "?") : unsure ? value + " ?" : value
        return { shown: shown, alpha: missing || confidence === 0 ? 0.55 : unsure ? 0.6 : 0.95 }
    }

    function options(key) {
        if (key === "agent") return ["claude", "codex", "shell"]
        if (key === "host") return root.plan ? root.plan.hosts : []
        return ["none (research)"].concat(root.plan ? root.plan.repos : [])
    }

    function pick(key, value) {
        const extra = {}
        extra[key] = key === "repo" && value === "none (research)" ? "" : value
        root.menuKey = ""
        send(extra)
    }

    function hint() {
        if (root.st.problem) return root.st.problem
        if (root.st.creating) return "naming the session…"
        if (root.st.recording) return "release Shift+F9 to review"
        if (root.st.finishing) return "finishing…"
        if (root.st.detecting && !root.plan) return "understanding…"
        const noRepo = root.plan && !(root.st.fixed && root.st.fixed.repo) && !root.plan.repo
        return (noRepo ? "no repo: in ~/agents   ·   " : "") + "Return creates   ·   hold Shift+F9 to say more   ·   Esc cancels"
    }

    FileView { id: stateFile; path: Quickshell.env("AGB_PANEL_STATE"); blockLoading: true }
    FileView { id: cmdFile; path: Quickshell.env("AGB_PANEL_CMD") }

    Timer {
        interval: 33; running: true; repeat: true
        onTriggered: {
            stateFile.reload()
            let s
            try { s = JSON.parse(stateFile.text()) } catch (e) { return }
            root.st = s
            try { root.plan = s.plan ? JSON.parse(s.plan) : null } catch (e) { root.plan = null }
            try { root.summary = s.summary ? JSON.parse(s.summary) : null } catch (e) { root.summary = null }
            // The host's text wins once it has applied our last edit.
            if (s.seq >= root.seq && s.text !== edit.text) {
                root.syncing = true
                edit.text = s.text
                edit.cursorPosition = edit.length
                root.syncing = false
            }
            const now = Date.now() / 1000
            const dt = Math.min(0.1, now - root.lastTick)
            root.lastTick = now
            root.phase += dt
            const target = s.recording ? s.level : 0
            root.level += (target - root.level) * (1 - Math.exp(-dt / (target > root.level ? 0.016 : 0.085)))
            core.requestPaint()
        }
    }

    PanelWindow {
        id: win
        implicitWidth: 600
        implicitHeight: body.y + body.height + 18 + (root.menuKey ? 212 : 0)
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "agent-belt-panel"

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 23
            border.color: root.ink(0.16)
            border.width: 0.75
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0.115, 0.125, 0.16, 0.98) }
                GradientStop { position: 1; color: Qt.rgba(0.065, 0.075, 0.1, 0.98) }
            }
        }

        // The dictation overlay's breathing core.
        Canvas {
            id: core
            x: 0; y: 0; width: 72; height: 76
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const cx = 36, cy = 38, t = root.phase
                const energy = Math.sqrt(Math.max(0, root.st.recording ? root.level : 0.02))
                const radius = 11 + energy * 2.8
                const halo = ctx.createRadialGradient(cx, cy, 0, cx, cy, 22)
                halo.addColorStop(0, root.css(0.11 + energy * 0.05))
                halo.addColorStop(1, root.css(0))
                ctx.fillStyle = halo
                ctx.beginPath()
                ctx.arc(cx, cy, 22, 0, 2 * Math.PI)
                ctx.fill()
                for (let layer = 0; layer < 3; layer++) {
                    ctx.beginPath()
                    for (let i = 0; i <= 90; i++) {
                        const a = i * 2 * Math.PI / 90
                        const r = radius + layer * 1.3 + Math.sin(a * 3 + t * 1.25 + layer * 1.7) * (1.1 + energy * 2)
                        const turn = t * 0.12 + layer * 0.25
                        const x = cx + Math.cos(a + turn) * r
                        const y = cy - Math.sin(a + turn) * r * 0.88
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.strokeStyle = "rgba(" + Math.round((0.58 + layer * 0.12) * 255) + ", " +
                        Math.round((0.76 - layer * 0.05) * 255) + ", 245, " + (0.58 - layer * 0.12) + ")"
                    ctx.lineWidth = 1.05
                    ctx.stroke()
                }
                const angle = t * (root.st.detecting ? 1.5 : 0.5)
                ctx.fillStyle = root.css(0.88)
                ctx.beginPath()
                ctx.arc(cx + Math.cos(angle) * radius, cy - Math.sin(angle) * radius * 0.88, 1.4, 0, 2 * Math.PI)
                ctx.fill()
            }
        }

        Row {
            x: 68; y: 16
            spacing: 10
            Text {
                text: root.st.recording ? "Listening for the new agent" : "New agent"
                color: root.ink(0.92)
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            // The session's name, as it will appear in every list.
            Text {
                visible: !root.st.recording && root.summary !== null
                text: "·  " + (root.summary ? root.summary.name : "")
                color: Qt.rgba(0.62, 0.86, 0.72, 0.98)
                font.family: "monospace"
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }
        }

        Column {
            id: body
            x: 68; y: 42
            width: 600 - 68 - 24
            spacing: 10

            Item {
                width: parent.width
                height: Math.min(180, Math.max(24, edit.contentHeight + 6))
                clip: true
                TextEdit {
                    id: edit
                    width: parent.width
                    y: Math.min(0, parent.height - height)
                    wrapMode: TextEdit.Wrap
                    color: root.ink(0.95)
                    selectionColor: root.ink(0.3)
                    font.pixelSize: 15
                    readOnly: !!(root.st.recording || root.st.finishing)
                    focus: true
                    cursorVisible: !readOnly
                    onTextChanged: if (!root.syncing) root.send({})
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            if (root.menuKey) root.menuKey = ""; else root.send({ action: "cancel" })
                            event.accepted = true
                        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                            root.send({ action: "create" })
                            event.accepted = true
                        }
                    }
                }
                Text {
                    visible: edit.length === 0 && !root.st.recording
                    text: "Say or type the agent: “codex no linux no web-app que investigue o login”"
                    color: root.ink(0.35)
                    font.pixelSize: 15
                }
            }

            Row {
                id: chips
                spacing: 8
                Repeater {
                    model: [["agent", "agent"], ["machine", "host"], ["repo", "repo"]]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property var info: root.chip(modelData[1])
                        height: 22
                        width: label.implicitWidth + 18
                        radius: 9
                        color: root.menuKey === modelData[1] ? root.ink(0.18) : root.ink(0.09)
                        Row {
                            id: label
                            anchors.centerIn: parent
                            spacing: 6
                            Text { text: modelData[0]; color: root.ink(0.5); font.pixelSize: 11; anchors.baseline: value.baseline }
                            Text { id: value; text: info.shown + " ▾"; color: root.ink(info.alpha); font.pixelSize: 12; font.weight: Font.Medium }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.menuKey = root.menuKey === modelData[1] ? "" : modelData[1]
                        }
                    }
                }
            }

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.summary ? "→ " + root.summary.summary : (edit.length > 0 && !root.st.recording ? "→ summarizing…" : "")
                color: root.ink(0.72)
                font.pixelSize: 13
            }

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.hint()
                color: root.ink(0.45)
                font.pixelSize: 11
            }
        }

        // The options of the chip being corrected, under the chips.
        Rectangle {
            visible: root.menuKey !== ""
            x: 68; y: body.y + chips.y + chips.height + 6
            width: 260; height: 200
            radius: 12
            color: Qt.rgba(0.09, 0.1, 0.13, 0.99)
            border.color: root.ink(0.16)
            border.width: 0.75
            ListView {
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                model: root.menuKey ? root.options(root.menuKey) : []
                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width
                    height: 26
                    radius: 7
                    color: hover.containsMouse ? root.ink(0.12) : "transparent"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        text: modelData
                        color: root.ink(0.9)
                        font.pixelSize: 13
                    }
                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.pick(root.menuKey, modelData)
                    }
                }
            }
        }
    }
}
