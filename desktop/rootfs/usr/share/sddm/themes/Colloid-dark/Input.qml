import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15

TextField {
    placeholderTextColor: "#8b8d93"
    palette.text: "#f4f3ef"
    font.pointSize: config.fontSize
    font.family: config.font
    width: parent.width
    // the unlock screen's field: ink, a slate edge, indigo while focused
    background: Rectangle {
        color: "#cc0b0c11"
        radius: 8
        border.width: 1
        border.color: parent.activeFocus ? "#8f9bff" : "#3a3e52"
    }
}
