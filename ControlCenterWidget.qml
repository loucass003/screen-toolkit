import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import qs.Services.UI
Item {
    id: root
    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    readonly property string screenName: screen?.name ?? ""
    readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
    readonly property real contentWidth: capsuleHeight
    readonly property real contentHeight: capsuleHeight
    implicitWidth: contentWidth
    implicitHeight: contentHeight
    readonly property bool _isRecording: (pluginApi?.mainInstance?.recordState ?? "") !== ""

    Rectangle {
        id: visualCapsule
        x: Style.pixelAlignCenter(parent.width, width)
        y: Style.pixelAlignCenter(parent.height, height)
        width: root.contentWidth
        height: root.contentHeight
        color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
        radius: Style.radiusL
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth
        NIcon {
            anchors.centerIn: parent
            icon: "crosshair"
            color: root._isRecording ? Color.mError || "#f44336" : Color.mPrimary
            SequentialAnimation on opacity {
                running: root._isRecording; loops: Animation.Infinite
                NumberAnimation { to: 0.4; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
            }
        }
    }
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: TooltipService.show(root, "Screen Toolkit", BarService.getTooltipDirection())
        onExited: TooltipService.hide()
        onClicked: {
            if (!pluginApi) return
            if ((pluginApi.mainInstance?.recordState ?? "") === "recording")
                pluginApi.mainInstance?.runRecordStop()
            else
                pluginApi.togglePanel(root.screen, root)
        }
    }
}
