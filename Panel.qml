import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Laya Attention popup: anchored beside the bar dot. Shows every agent
// herdr tracks with its last Laya decision, plus watcher controls.
//
// BarWidget.qml owns the bar dot and hands this panel the button to anchor
// against — same shape contract as the clock's calendar popup (open/close/
// toggle/closeForPopoutSwitch on the bar-widget root, injected here).
Panel {
  id: root
  moduleName: "laya-attention"
  ipcTarget: "laya-attention"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The service loads after the panel sometimes; look it up late.
  property var lookedUp: null
  property int lookups: 0
  readonly property var svc: service || lookedUp

  function findService() {
    if (!service && !lookedUp && shell && typeof shell.serviceFor === "function")
      lookedUp = shell.serviceFor("laya-attention")
  }

  // ---------------------------------------------------------------- state

  property var agents: ({})      // pane -> {status, title}
  property var decisions: ({})   // pane -> last decision row
  property int notifiedCount: 0
  property int triageSuppressed: 0
  property string lastTriage: ""

  // Live settings, mirrored from the service (the source of truth). The
  // sliders edit these through setSetting, which persists to shell.json.
  property real attentionThreshold: 0.45
  property real triageThreshold: 0.6
  property bool triageEnabled: true

  function setSetting(key, value) {
    if (svc) {
      svc.applySetting(key, value)
      var patch = {}
      patch[key] = value
      svc.persistSetting(patch)
    }
  }

  function open() {
    refresh()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? close() : open() }

  function refresh() {
    agentsFile.reload()
    decisionsFile.reload()
    triageFile.reload()
  }

  function parseAgents(raw) {
    try { root.agents = JSON.parse(raw || "{}") } catch (e) { root.agents = {} }
  }

  function parseDecisions(raw) {
    var lines = (raw || "").trim().split("\n").filter(Boolean)
    var last = {}
    var count = 0
    for (var i = 0; i < lines.length; i++) {
      try {
        var d = JSON.parse(lines[i])
        last[d.pane] = d
      } catch (e) {}
    }
    for (var pane in last) if (last[pane].action === "notified") count++
    root.decisions = last
    root.notifiedCount = count
  }

  function parseTriage(raw) {
    var lines = (raw || "").trim().split("\n").filter(Boolean)
    var count = 0
    var last = ""
    for (var i = 0; i < lines.length; i++) {
      try {
        var d = JSON.parse(lines[i])
        if (d.action === "suppressed") {
          count++
          last = (d.app || "?") + " — " + (d.summary || "") + " (" + (d.kind || "?") + " " + Number(d.kind_prob || 0).toFixed(2) + ")"
        }
      } catch (e) {}
    }
    root.triageSuppressed = count
    if (last) root.lastTriage = last
  }

  function kindColor(action) {
    return action === "notified" ? Color.accent : Color.muted
  }

  // ---------------------------------------------------------------- files

  FileView {
    id: agentsFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/laya-attention/agents.json"
    printErrors: false
    onLoaded: root.parseAgents(text())
  }

  FileView {
    id: decisionsFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/laya-attention/decisions.jsonl"
    printErrors: false
    onLoaded: root.parseDecisions(text())
  }

  FileView {
    id: triageFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/laya-attention/triage.jsonl"
    printErrors: false
    onLoaded: root.parseTriage(text())
  }

  // Mirror service settings into the panel while open (the sliders are
  // edited locally through setSetting; the service remains the truth).
  Timer {
    interval: 1000
    repeat: true
    running: panel.open && !!root.svc
    onTriggered: {
      if (!root.svc) return
      if (!attentionSlider.dragging) root.attentionThreshold = root.svc.threshold
      if (!triageSlider.dragging) root.triageThreshold = root.svc.triageThreshold
      root.triageEnabled = !!root.svc.triageEnabled
    }
  }

  Timer {
    interval: 500
    repeat: true
    running: panel.open && !root.svc && root.lookups < 20
    onTriggered: { root.lookups++; root.findService() }
  }

  // ---------------------------------------------------------------- view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      width: parent.width
      spacing: Style.spacing.sm

      PanelHero {
        width: parent.width
        title: "Laya Attention"
        meta: {
          if (!root.svc) return "service not loaded"
          return svc.layaUp ? "decision server up · " + (svc.agentCount || Object.keys(root.agents).length) + " agents"
                            : "decision server down (localhost:8000)"
        }
      }

      PanelSeparator {}

      PanelSectionHeader { width: parent.width; text: "Agents" }

      // Agent rows: status dot, title, last decision.
      Repeater {
        model: Object.keys(root.agents).sort()

        delegate: Column {
          id: agentRow
          required property string modelData
          readonly property var agent: root.agents[modelData] || {}
          readonly property var dec: root.decisions[modelData] || null
          width: parent.width
          spacing: 2

          readonly property bool isFirst: modelData === Object.keys(root.agents).sort()[0]

          Rectangle {
            width: parent.width
            height: 1
            color: Color.popups.border
            visible: !isFirst
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Rectangle {
              width: 8; height: 8; radius: 4
              anchors.verticalCenter: parent.verticalCenter
              color: dec && dec.action === "notified" ? Color.accent : Color.muted
              opacity: dec && dec.action === "notified" ? 1.0 : 0.5
            }

            Column {
              width: parent.width - 20
              spacing: 0

              Text {
                width: parent.width
                text: agent.title || agentRow.modelData
                color: Color.popups.text
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: dec ? (dec.kind + " · " + Number(dec.prob).toFixed(2) + " · " + dec.action)
                          : "no decision yet"
                color: Color.muted
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      PanelSeparator {}

      PanelSectionHeader { width: parent.width; text: "Controls" }

      // Triage summary
      Text {
        width: parent.width
        text: root.triageSuppressed > 0
          ? root.triageSuppressed + " suppressed - last: " + root.lastTriage
          : "no notifications suppressed yet"
        color: Color.muted
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Column {
        width: parent.width
        spacing: 4

        Item {
          width: parent.width
          height: Math.max(leftLabel.implicitHeight, rightLabel.implicitHeight)

          Text {
            id: leftLabel
            text: "Suppress notifications at"
            color: Color.popups.text
            font.pixelSize: Style.font.bodySmall
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: rightLabel
            text: Math.round(root.triageThreshold * 100) + "%"
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: triageSlider
          width: parent.width
          minimum: 0.5
          maximum: 0.95
          step: 0.05
          value: root.triageThreshold
          onReleased: function (v) { root.setSetting("triageThreshold", v) }
        }
      }

      Column {
        width: parent.width
        spacing: 4

        Item {
          width: parent.width
          height: Math.max(attnLeft.implicitHeight, attnRight.implicitHeight)

          Text {
            id: attnLeft
            text: "Agent attention at"
            color: Color.popups.text
            font.pixelSize: Style.font.bodySmall
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: attnRight
            text: Math.round(root.attentionThreshold * 100) + "%"
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: attentionSlider
          width: parent.width
          minimum: 0.3
          maximum: 0.95
          step: 0.05
          value: root.attentionThreshold
          onReleased: function (v) { root.setSetting("threshold", v) }
        }
      }

      Item {
        width: parent.width
        height: Math.max(triageLabel.implicitHeight, triageToggle.implicitHeight)

        Text {
          id: triageLabel
          text: "Triage enabled"
          color: Color.popups.text
          font.pixelSize: Style.font.bodySmall
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          id: triageToggle
          text: root.triageEnabled ? "On" : "Off"
          active: root.triageEnabled
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.setSetting("triageEnabled", !root.triageEnabled)
        }
      }

      Item { width: 1; height: Style.space(2) }

      Row {
        spacing: Style.spacing.sm

        Button {
          text: "Poll now"
          onClicked: {
            if (root.svc) root.svc.poll()
            pollTimer.restart()
          }
        }

        Button {
          text: "Refresh"
          onClicked: root.refresh()
        }
      }
    }
  }

  Timer {
    id: pollTimer
    interval: 1500
    onTriggered: root.refresh()
  }
}
