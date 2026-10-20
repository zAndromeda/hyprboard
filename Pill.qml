import QtQuick

// small rounded button used all over the panel
Rectangle {
    id: pill
    property string text: ""
    property bool danger: false
    property bool active: false
    property int fontSize: 11
    // palette: { fg, mute, acc, ring, danger }, passed in from shell.qml
    property var pal: ({ fg: "#ececef", mute: "#8d8d96", acc: "#8fb0ff", ring: "#1fffffff", danger: "#ff6b6b" })
    signal clicked()

    implicitWidth: lbl.implicitWidth + 22
    implicitHeight: 26
    radius: height / 2
    color: area.pressed ? (danger ? pal.danger : pal.acc)
         : (danger && area.containsMouse) ? Qt.rgba(1, 0.42, 0.42, 0.35)
         : active ? Qt.rgba(pal.acc.r, pal.acc.g, pal.acc.b, 0.35)
         : area.containsMouse ? Qt.rgba(pal.fg.r, pal.fg.g, pal.fg.b, 0.2)
         : pal.ring
    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
        id: lbl
        anchors.centerIn: parent
        text: pill.text
        color: area.pressed ? "#16161a" : pill.pal.fg
        font.pixelSize: pill.fontSize
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        onClicked: pill.clicked()
    }
}
