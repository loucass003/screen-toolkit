import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Widgets
import qs.Services.UI

Item {
    id: root
    property var pluginApi: null
    property string region: ""
    property string mp4Path: ""
    property string gifPath: ""
    // recordState: "" | "recording" | "converting" | "done"
    property string recordState: ""
    readonly property bool isRecording:  recordState === "recording"
    readonly property bool isConverting: recordState === "converting"
    readonly property bool isDone:       recordState === "done"
    property int regionX: 0
    property int regionY: 0
    property int regionW: 400
    property int regionH: 300
    property int uiX: 0
    property int uiY: 0
    property var _primaryScreen: null
    property int _elapsed: 0
    property string format: "gif"
    property bool audioOutput: false
    property bool audioInput: false
    property bool includeCursor: false
    property string _recorderBin: "wl-screenrec"
    signal dismissed()

    function _expandPath(p) {
        if (!p || p === "") return ""
        if (p.startsWith("~/"))
            return Quickshell.env("HOME") + "/" + p.substring(2)
        return p
    }

    function _recordOutputDir() {
        var custom = pluginApi?.pluginSettings?.videoPath ?? ""
        if (custom !== "") return _expandPath(custom.trim().replace(/\/$/, ""))
        return Quickshell.env("HOME") + "/Videos"
    }

    function _buildFilename(toolName, ext) {
        var fmt = pluginApi?.pluginSettings?.filenameFormat ?? ""
        if (fmt.trim() !== "") {
            var now = new Date()
            var name = fmt.trim()
                .replace(/%Y/g, Qt.formatDateTime(now, "yyyy"))
                .replace(/%m/g, Qt.formatDateTime(now, "MM"))
                .replace(/%d/g, Qt.formatDateTime(now, "dd"))
                .replace(/%H/g, Qt.formatDateTime(now, "HH"))
                .replace(/%M/g, Qt.formatDateTime(now, "mm"))
                .replace(/%S/g, Qt.formatDateTime(now, "ss"))
                .replace(/[\/\\\n\r\0]/g, "_").trim()
            if (name !== "") return name + ext
        }
        return toolName + "-" + Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss") + ext
    }

    function startRecording(regionStr, fmt, audOut, audIn, cursor, uiOffsetX, uiOffsetY, screen) {
        if (root.isRecording || root.isConverting) return
        root.format        = (fmt === "mp4") ? "mp4" : "gif"
        root.audioOutput   = audOut  === true
        root.audioInput    = audIn   === true
        root.includeCursor = cursor  === true
        var parts = regionStr.trim().split(" ")
        if (parts.length >= 2) {
            var xy = parts[0].split(",")
            var wh = parts[1].split("x")
            root.regionX = parseInt(xy[0]) || 0
            root.regionY = parseInt(xy[1]) || 0
            root.regionW = parseInt(wh[0]) || 400
            root.regionH = parseInt(wh[1]) || 300
        }
        root.uiX = uiOffsetX || 0
        root.uiY = uiOffsetY || 0
        root._primaryScreen = screen ?? Quickshell.screens[0] ?? null
        root._recorderBin = (pluginApi?.mainInstance?.detectedRecorder === "wf-recorder")
                            ? "wf-recorder" : "wl-screenrec"
        root.region       = regionStr
        root.mp4Path      = "/tmp/screen-toolkit-record-" + Date.now() + ".mp4"
        root.gifPath      = ""
        root.recordState = "recording"
        root._elapsed = 0
        elapsedTimer.start()
        var cmd
        if (root._recorderBin === "wf-recorder") {
            cmd = "wf-recorder -g " + shellEscape(regionStr) +
                  (root.audioOutput
                      ? " -a=$(pactl get-default-sink 2>/dev/null).monitor"
                      : root.audioInput
                          ? " -a=$(pactl get-default-source 2>/dev/null)"
                          : "") +
                  " -f " + shellEscape(root.mp4Path) + " 2>/dev/null" +
                  "; [ -s " + shellEscape(root.mp4Path) + " ] && exit 0 || exit 1"
        } else {
            cmd = "wl-screenrec -g " + shellEscape(regionStr) +
                  (root.includeCursor ? "" : " --no-cursor") +
                  (root.audioOutput
                      ? " --audio --audio-device $(pactl get-default-sink 2>/dev/null).monitor"
                      : root.audioInput
                          ? " --audio --audio-device $(pactl get-default-source 2>/dev/null)"
                          : "") +
                  " -f " + shellEscape(root.mp4Path) + " 2>/dev/null" +
                  "; [ -s " + shellEscape(root.mp4Path) + " ] && exit 0 || exit 1"
        }
        wfRecorderProc.exec({ command: ["bash", "-c", cmd] })
    }

    function stopRecording() {
        if (!root.isRecording) return
        elapsedTimer.stop()
        stopProc.exec({ command: ["bash", "-c", "pkill -INT " + root._recorderBin + " 2>/dev/null || true"] })
    }

    function dismiss() {
        var toClipboard = root.pluginApi?.pluginSettings?.recordCopyToClipboard ?? false
        if (root.gifPath !== "" && !toClipboard)
            stopProc.exec({ command: ["bash", "-c", "rm -f " + shellEscape(root.gifPath)] })
        root.recordState = ""
        root.gifPath        = ""
        root._primaryScreen = null
        root.dismissed()
    }

    function shellEscape(str) {
        return "'" + str.replace(/'/g, "'\\''") + "'"
    }

    function _handleDone() {
        var skipConfirm = root.pluginApi?.pluginSettings?.recordSkipConfirmation ?? false
        var toClipboard = root.pluginApi?.pluginSettings?.recordCopyToClipboard  ?? false
        if (skipConfirm) {
            _saveToFile()  // saveProc.onExited handles clipboard + dismiss
        } else if (toClipboard) {
            _copyPathToClipboard(root.gifPath)
            ToastService.showNotice(root.pluginApi?.tr("record.copiedToClipboard"))
            root.dismiss()
        } else {
            root.recordState = "done"
        }
    }

    function _copyPathToClipboard(path) {
        var cmd = "printf 'file://%s\\r\\n' " + shellEscape(path) +
                  " | wl-copy --type text/uri-list"
        clipProc.exec({ command: ["bash", "-c", cmd] })
    }

    function _saveToFile() {
        var ext  = root.format === "mp4" ? ".mp4" : ".gif"
        var dir  = root._recordOutputDir()
        var dest = dir + "/" + root._buildFilename("record", ext)
        saveProc.savedPath = dest
        saveProc.exec({ command: ["bash", "-c",
            "mkdir -p " + shellEscape(dir) + " && " +
            "cp " + shellEscape(root.gifPath) + " " + shellEscape(dest)
        ]})
    }

    Process {
        id: wfRecorderProc
        onExited: (code) => {
            elapsedTimer.stop()
            if (code === 0 || code === 130 || code === 2) {
                root.recordState = "converting"
                var tmpTs    = Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")
                var optimOut = "/tmp/screen-toolkit-record-" + tmpTs
                if (root.format === "mp4") {
                    root.gifPath = optimOut + ".mp4"
                    gifConvertProc.exec({ command: [
                        "bash", "-c",
                        "ffmpeg -y -i " + shellEscape(root.mp4Path) +
                        " -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2'" +
                        " -c:v libx264 -crf 18 -preset slow -tune animation" +
                        " -pix_fmt yuv420p -movflags +faststart" +
                        (root.audioOutput || root.audioInput ? " -c:a aac -b:a 128k" : " -an") +
                        " " + shellEscape(root.gifPath) + " 2>/dev/null && " +
                        "rm -f " + shellEscape(root.mp4Path) + " && " +
                        "ffmpeg -y -ss 0 -i " + shellEscape(root.gifPath) +
                        " -frames:v 1 /tmp/screen-toolkit-record-thumb.png 2>/dev/null; exit 0"
                    ]})
                } else {
                    root.gifPath = optimOut + ".gif"
                    var framesDir = "/tmp/screen-toolkit-frames-" + Date.now()
                    gifConvertProc.exec({ command: [
                        "bash", "-c",
                        "mkdir -p " + shellEscape(framesDir) + " && " +
                        "ffmpeg -y -i " + shellEscape(root.mp4Path) +
                        " -vf 'fps=20,scale=if(gt(iw\\,960)\\,960\\,iw):-2:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2'" +
                        " " + shellEscape(framesDir) + "/frame%04d.png 2>/dev/null && " +
                        "gifski --fps 20 --quality 95 -o " + shellEscape(root.gifPath) +
                        " " + shellEscape(framesDir) + "/frame*.png 2>/dev/null && " +
                        "rm -rf " + shellEscape(framesDir) + " " + shellEscape(root.mp4Path)
                    ]})
                }
            } else {
                root.dismiss()
                ToastService.showError(root.pluginApi?.tr("record.failed"))
            }
        }
    }

    Process { id: stopProc }

    Process {
        id: gifConvertProc
        onExited: (code) => {
            if (code === 0) {
                _handleDone()
            } else {
                root.dismiss()
                ToastService.showError(root.format === "mp4"
                    ? root.pluginApi?.tr("record.saveMp4Failed")
                    : root.pluginApi?.tr("record.saveGifFailed"))
            }
        }
    }

    Process {
        id: saveProc
        property string savedPath: ""
        onExited: (code) => {
            if (code === 0) {
                var toClipboard = root.pluginApi?.pluginSettings?.recordCopyToClipboard ?? false
                if (toClipboard) _copyPathToClipboard(saveProc.savedPath)
                var msg = toClipboard
                    ? root.pluginApi?.tr("record.savedAndCopied")
                    : root.pluginApi?.tr("record.saved")
                ToastService.showNotice(msg, saveProc.savedPath, "device-floppy")
            } else {
                ToastService.showError(root.format === "mp4"
                    ? root.pluginApi?.tr("record.saveMp4Failed")
                    : root.pluginApi?.tr("record.saveGifFailed"))
            }
            root.dismiss()
        }
    }

    Process { id: clipProc }

    Timer {
        id: elapsedTimer
        interval: 1000; repeat: true
        onTriggered: {
            root._elapsed++
            if (root.format === "gif" && root._elapsed >= 30)
                root.stopRecording()
        }
    }

    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: recWin
            required property ShellScreen modelData
            readonly property bool isPrimary: modelData === root._primaryScreen
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            visible: root.isRecording
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "noctalia-record"
            // Border around region
            Rectangle {
                visible: isPrimary
                x: root.uiX - 4; y: root.uiY - 4
                width: root.regionW + 8; height: root.regionH + 8
                color: "transparent"
                border.color: Color.mError || "#f44336"; border.width: 2; radius: 3; opacity: 0.85
            }

            // Stop button — positioned via child Item so parent.height/width resolves correctly
            Item {
                id: stopBtnAnchor
                visible: isPrimary
                readonly property real btnW: 110
                readonly property real btnH: 36
                readonly property real spaceBelow: parent.height - (root.uiY + root.regionH)
                x: Math.max(8, Math.min(root.uiX + (root.regionW - btnW) / 2, parent.width - btnW - 8))
                y: spaceBelow >= btnH + 10 ? root.uiY + root.regionH + 8 : root.uiY - btnH - 8
                width: btnW; height: btnH

                Rectangle {
                    anchors.fill: parent
                    radius: Style.radiusL
                    color: stopMA.containsMouse ? Color.mError || "#f44336" : Color.mSurface
                    border.color: Color.mError || "#f44336"; border.width: 2
                    Row {
                        anchors.centerIn: parent; spacing: Style.marginS
                        Rectangle {
                            width: 10; height: 10; radius: 2
                            color: stopMA.containsMouse ? "white" : Color.mError || "#f44336"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        NText {
                            text: root.pluginApi?.tr("record.stop") ?? "Stop"
                            color: stopMA.containsMouse ? "white" : Color.mOnSurface
                            font.weight: Font.Bold; pointSize: Style.fontSizeS
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    MouseArea {
                        id: stopMA; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.stopRecording()
                    }
                }
            }

            Item { id: maskItem; x: stopBtnAnchor.x; y: stopBtnAnchor.y; width: stopBtnAnchor.btnW; height: stopBtnAnchor.btnH }
            mask: Region { item: isPrimary ? maskItem : null }
        }
    }
}
