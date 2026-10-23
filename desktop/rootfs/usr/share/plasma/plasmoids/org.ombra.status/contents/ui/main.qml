// Ombra Tor-status dot — the top-bar LED. A colored dot plus a tooltip;
// clicking opens the connectivity detail. Data contract pinned by
// core/src/status.rs: one JSON line {"state":...,"tooltip":...}, shown
// as green (ok) / yellow (semi) / red (fail) / grey (unknown); the
// tooltip is the daemon's own string.
//
// Mechanism: QML cannot open unix sockets, so an `executable`
// dataengine runs `ombra-statusd --once` with OMBRA_STATUS_FORCE_CACHE=1
// — the dot always reads the daemon's persisted verdict, never probes.
// Interval 31 s once green (one tick behind the daemon's 30 s TTL), 2 s until then.
// Fail-soft: any malformed/empty/foreign line renders grey "not
// answering"; nothing here can take plasmashell down.

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.components 3 as PC3
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    // FORCE_CACHE: the daemon owns probing; env(1) keeps it one command line
    readonly property string statusCommand: "/usr/bin/env OMBRA_STATUS_FORCE_CACHE=1 /usr/local/bin/ombra-statusd --once"

    readonly property var stateColors: ({
        "ok": "#56d68a",
        "semi": "#f2c260",
        "fail": "#f0716b",
        "unknown": "#8b8d93"
    })
    readonly property string errorColor: "#8b8d93"
    readonly property string errorTooltip: "Ombra: status daemon not answering"

    property string dotColor: errorColor
    property string statusText: errorTooltip
    property var detail: null

    // update notice (tooltip only): the root-owned boot-time check writes "available" and the version to /run/ombra/update
    property string updateVersion: ""
    readonly property string updateCommand: "/usr/bin/head -n 2 /run/ombra/update"

    // dot size from gridUnit — FontMetrics.height can arrive NaN at
    // item creation (Math.max(8, NaN) = NaN = a dot that never draws),
    // and gridUnit is always a plain number
    readonly property real dotSize: Math.max(8, Math.round(Kirigami.Units.gridUnit * 0.7))

    switchWidth: Kirigami.Units.gridUnit * 8
    switchHeight: Kirigami.Units.gridUnit * 8

    toolTipMainText: "Ombra Tor Status"
    toolTipSubText: root.updateVersion !== ""
        ? root.statusText + "\nOmbra " + root.updateVersion + " is available. Open Update Ombra from the application menu."
        : root.statusText

    P5Support.DataSource {
        id: statusSource

        engine: "executable"
        // one tick behind the daemon's 30 s cache TTL; reads the cache every 2 s until the first all-clear
        interval: root.dotColor === root.stateColors["ok"] ? 31000 : 2000
        connectedSources: [root.statusCommand]
        onNewData: (source, data) => {
            root.ingest(data["stdout"]);
        }
    }

    P5Support.DataSource {
        id: updateSource

        engine: "executable"
        interval: 60000
        connectedSources: [root.updateCommand]
        onNewData: (source, data) => {
            const lines = String(data["stdout"] || "").trim().split("\n");
            const ver = (lines.length > 1 ? lines[1] : "").trim();
            // only a plain version string is ever shown
            root.updateVersion = (lines[0].trim() === "available" && /^[0-9][0-9A-Za-z.+~-]{0,30}$/.test(ver)) ? ver : "";
        }
    }

    // anything not exactly the pinned shape reads as "not answering"
    function ingest(stdoutText) {
        const line = String(stdoutText || "").trim().split("\n")[0];
        let snap = null;
        try {
            snap = JSON.parse(line);
        } catch (e) {
            snap = null;
        }
        if (!snap || typeof snap !== "object"
            || typeof snap.state !== "string"
            || !root.stateColors.hasOwnProperty(snap.state)
            || typeof snap.tooltip !== "string"
            || snap.tooltip.length === 0) {
            root.dotColor = root.errorColor;
            root.statusText = root.errorTooltip;
            root.detail = null;
            return;
        }
        root.dotColor = root.stateColors[snap.state];
        // the daemon's copy verbatim (pinned escape-free in status.rs)
        root.statusText = snap.tooltip;
        root.detail = {
            "gateway": snap.gateway === true,
            "tor": snap.tor === true,
            "dns": snap.dns === true,
            "timesync": typeof snap.timesync === "string" ? snap.timesync : ""
        };
    }

    compactRepresentation: Component {
        Item {
            implicitWidth: root.dotSize + Math.round(root.dotSize / 2)
            implicitHeight: root.dotSize

            Rectangle {
                anchors.centerIn: parent
                width: root.dotSize
                height: width
                radius: width / 2
                color: root.dotColor
            }
        }
    }

    fullRepresentation: Component {
        Item {
            implicitWidth: Kirigami.Units.gridUnit * 17
            implicitHeight: card.implicitHeight + Kirigami.Units.gridUnit * 2

            ColumnLayout {
                id: card

                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 2
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.preferredWidth: root.dotSize
                        Layout.preferredHeight: root.dotSize
                        radius: width / 2
                        color: root.dotColor
                    }

                    Kirigami.Heading {
                        Layout.fillWidth: true
                        level: 4
                        text: "Ombra Tor Status"
                        elide: Text.ElideRight
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                PC3.Label {
                    Layout.fillWidth: true
                    text: root.statusText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.smallSpacing
                }

                Repeater {
                    model: root.detail === null ? [] : [
                        {
                            "label": "Gateway",
                            "ok": root.detail.gateway,
                            "yes": "reachable",
                            "no": "unreachable"
                        },
                        {
                            "label": "Tor circuit",
                            "ok": root.detail.tor,
                            "yes": "routed through Tor",
                            "no": "not routed"
                        },
                        {
                            "label": "DNS",
                            "ok": root.detail.dns,
                            "yes": "resolving through Tor",
                            "no": "not resolving"
                        },
                        {
                            "label": "Time sync",
                            "ok": root.detail.timesync === "ok",
                            "yes": "in sync",
                            "no": root.detail.timesync === "" ? "unknown" : root.detail.timesync
                        }
                    ]

                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            source: model.modelData.ok ? "dialog-ok" : "dialog-cancel"
                        }

                        PC3.Label {
                            Layout.fillWidth: true
                            text: model.modelData.label
                        }

                        PC3.Label {
                            Layout.alignment: Qt.AlignRight
                            text: model.modelData.ok ? model.modelData.yes : model.modelData.no
                            opacity: model.modelData.ok ? 1 : 0.7
                        }
                    }
                }

                PC3.Label {
                    Layout.fillWidth: true
                    opacity: 0.6
                    text: "every connection routes through the Ombra gateway"
                }
            }
        }
    }
}
