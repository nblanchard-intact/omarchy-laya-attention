import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The Laya Attention bar widget: a small dot.
//   · dim dot   — service running, no agent attention
//   · accent    — at least one agent flagged as needing attention
//   · hollow    — the laya decision server is unreachable
// Click re-posts the last attention decision as a herdr notification.
BarWidget {
  id: root
  moduleName: "laya-attention"

  readonly property var service: {
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor(root.moduleName)
  }
  readonly property bool needsAttention: !!service && service.attentionAgents > 0
  readonly property bool layaUp: !!service && service.layaUp
  readonly property string lastDecision: service ? (service.lastDecision || "") : ""

  readonly property string tooltip: {
    if (!service) return "Laya Attention"
    if (!layaUp) return "Laya Attention · decision server down (localhost:8000)"
    if (!needsAttention) return "Laya Attention · all agents quiet"
    var n = service.attentionAgents
    return "Laya Attention · " + n + " agent" + (n === 1 ? "" : "s") + " need" + (n === 1 ? "s" : "") + " attention" +
           (lastDecision ? "\n" + lastDecision : "")
  }

  // ---- Popup contract (Bar.findPanelWidget): open/close/opened on the
  //      bar-widget root; the panel is loaded from Panel.qml and anchored
  //      to the button.
  property var anchorItem: button
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : dot.width + button.scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? dot.height + button.scaledVerticalPadding * 2 : -1
    tooltipText: root.tooltip

    Rectangle {
      id: dot
      anchors.centerIn: parent
      width: 8
      height: 8
      radius: 4
      color: root.needsAttention ? Color.accent
           : root.layaUp         ? button.foreground
           :                       "transparent"
      opacity: root.needsAttention ? 1.0 : 0.55
      border.width: root.layaUp ? 0 : 1
      border.color: button.foreground
    }

    onPressed: function (mouseButton) {
      if (mouseButton !== Qt.LeftButton) return
      root.togglePanel()
    }
  }
}
