// Agent Belt's dictation overlay on Linux, drawn like the macOS one
// (src/status_item.m): a core that breathes with the voice, ribbons that follow
// it, and a phrase that keeps deciphering while the text is on its way.
// agb writes "<mode> <level>" to $AGB_OVERLAY_STATE: mode 1 listening,
// 2 transcribing, 0 hidden, -1 quit; level 0..1.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    property int mode: 0
    property real level: 0
    property real releaseLevel: 0
    property real motion: 0
    property real previousTarget: 0
    property real phase: 0
    property real signalPhase: 0
    property real modeStarted: 0
    property real lastTick: Date.now() / 1000

    function ease(t) { t = Math.max(0, Math.min(1, t)); return t * t * (3 - 2 * t) }
    function ink(a) { return "rgba(184, 201, 245, " + a + ")" }

    FileView { id: state; path: Quickshell.env("AGB_OVERLAY_STATE"); blockLoading: true }

    Timer {
        interval: 16; running: true; repeat: true
        onTriggered: {
            state.reload()
            const parts = state.text().trim().split(" ")
            const m = parseInt(parts[0]) || 0
            if (m === -1) { Qt.quit(); return }
            const now = Date.now() / 1000
            const dt = Math.min(0.1, now - root.lastTick)
            root.lastTick = now
            if (m !== root.mode) { root.releaseLevel = root.level; root.mode = m; root.modeStarted = now }
            root.phase += dt
            // Fast attack follows syllables; the short release leaves space between words.
            const target = m === 1 ? (parseFloat(parts[1]) || 0) : 0
            root.level += (target - root.level) * (1 - Math.exp(-dt / (target > root.level ? 0.016 : 0.085)))
            const onset = Math.max(0, target - root.previousTarget - 0.025)
            root.motion = Math.max(Math.min(1, onset * 2.5), root.motion * Math.exp(-dt / 0.1))
            root.previousTarget = target
            root.signalPhase += dt * (2 + root.level * 10 + root.motion * 14)
            if (root.mode > 0) canvas.requestPaint()
        }
    }

    PanelWindow {
        visible: root.mode > 0
        anchors { top: true; right: true }
        margins { top: 14; right: 18 }
        implicitWidth: 252
        implicitHeight: 78
        color: "transparent"
        exclusionMode: ExclusionMode.Normal // below the bar, as on the Mac
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "agent-belt"
        mask: Region {}

        Canvas {
            id: canvas
            anchors.fill: parent
            opacity: root.mode > 0 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const now = Date.now() / 1000
                const t = root.phase
                const morph = root.mode === 2 ? root.ease((now - root.modeStarted) / 0.7) : 0

                // Shell: a rounded surface with a faint edge.
                const g = ctx.createLinearGradient(0, 0, 0, height)
                g.addColorStop(0, "rgba(29, 32, 41, 0.98)")
                g.addColorStop(1, "rgba(17, 19, 26, 0.98)")
                ctx.fillStyle = g
                ctx.beginPath()
                ctx.roundedRect(2, 2, width - 4, height - 4, 23, 23)
                ctx.fill()
                ctx.strokeStyle = root.ink(0.16)
                ctx.lineWidth = 0.75
                ctx.stroke()

                drawCore(ctx, t, morph)
                ctx.fillStyle = root.ink(0.92)
                ctx.font = "500 12px sans-serif"
                ctx.fillText(root.mode === 1 ? "Listening" : "Transcribing", 65, 30)
                drawSignal(ctx, t, morph)
            }

            function drawCore(ctx, t, morph) {
                const cx = 34, cy = 39
                const energy = Math.sqrt(Math.max(0, root.level))
                const radius = 11 + energy * 2.8
                // A low-contrast halo and three drifting contours share the same center.
                const halo = ctx.createRadialGradient(cx, cy, 0, cx, cy, 22)
                halo.addColorStop(0, root.ink(0.11 + energy * 0.05))
                halo.addColorStop(1, root.ink(0))
                ctx.fillStyle = halo
                ctx.beginPath()
                ctx.arc(cx, cy, 22, 0, 2 * Math.PI)
                ctx.fill()
                for (let layer = 0; layer < 3; layer++) {
                    ctx.beginPath()
                    for (let i = 0; i <= 90; i++) {
                        const a = i * 2 * Math.PI / 90
                        const ripple = Math.sin(a * 3 + t * 1.25 + layer * 1.7) * (1.1 + energy * 2) * (1 - morph * 0.6)
                        const r = radius + layer * 1.3 + ripple
                        const turn = t * (0.12 + morph * 0.25) + layer * 0.25
                        const x = cx + Math.cos(a + turn) * r
                        const y = cy - Math.sin(a + turn) * r * 0.88
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.strokeStyle = "rgba(" + Math.round((0.58 + layer * 0.12) * 255) + ", " +
                        Math.round((0.76 - layer * 0.05) * 255) + ", 245, " + (0.58 - layer * 0.12) + ")"
                    ctx.lineWidth = 1.05
                    ctx.stroke()
                }
                const angle = t * (root.mode === 2 ? 1.5 : 0.5)
                ctx.fillStyle = root.ink(0.88)
                ctx.beginPath()
                ctx.arc(cx + Math.cos(angle) * radius, cy - Math.sin(angle) * radius * 0.88, 1.4, 0, 2 * Math.PI)
                ctx.fill()
            }

            function drawSignal(ctx, t, morph) {
                const energy = Math.max(0, root.mode === 1 ? root.level : root.releaseLevel)
                const travel = root.signalPhase
                const detail = root.motion
                // Continuous ribbons settle into the typographic baseline.
                for (let layer = 0; layer < 3; layer++) {
                    ctx.beginPath()
                    for (let i = 0; i <= 90; i++) {
                        const u = i / 90
                        const envelope = Math.pow(Math.sin(u * Math.PI), 1.5)
                        const amplitude = (0.5 + energy * 14.5) * envelope * (1 - morph)
                        const y = 50 - amplitude * (Math.sin(u * (4 + detail * 2) * Math.PI - travel + layer * 0.6) * 0.72 +
                                                    Math.sin(u * 9 * Math.PI + travel * 0.6) * 0.28)
                        const inset = 28 * root.ease(morph * 2)
                        const x = 66 + inset + u * (160 - inset)
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.strokeStyle = root.ink((0.7 - layer * 0.19) * (1 - morph))
                    ctx.lineWidth = 1.2
                    ctx.stroke()
                }
                if (morph > 0) drawCipher(ctx, t, root.ease((morph - 0.25) / 0.75))
            }

            // Letters settle left to right, hold, then scramble again.
            function drawCipher(ctx, t, opacity) {
                const phrase = "deciphering your voice"
                const pool = "abcdefghijklmnopqrstuvwxyz0123456789#$%&*+=<>/\\|?!"
                const cycle = 2.8, local = (t % cycle) / cycle
                const count = phrase.length
                const settled = local < 0.45 ? local / 0.45 * count : local < 0.75 ? count : (1 - (local - 0.75) / 0.25) * count
                const tick = Math.floor(t * 18)
                for (let i = 0; i < count; i++) {
                    const target = phrase[i]
                    const fixed = i < settled || target === " "
                    let glyph = target
                    if (!fixed) {
                        const h = ((Math.imul(i, 2654435761) >>> 0) ^ ((tick * 40503 + i * 97) >>> 0)) >>> 0
                        glyph = pool[(h >>> 3) % pool.length]
                    }
                    ctx.font = (fixed ? "500" : "400") + " 11px monospace"
                    ctx.fillStyle = root.ink(opacity * (fixed ? 0.85 : 0.4))
                    ctx.fillText(glyph, 66 + i * 7.4, 57)
                }
            }
        }
    }
}
