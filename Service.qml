import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Laya Attention service.
//
// Owns the poll loop: every `intervalMs` it runs lib/poll.py, which asks
// herdr for agent panes, detects working -> idle transitions, reads the pane
// tail, classifies it through the local Laya decision server (laya-serve on
// localhost:8000), and fires a herdr notification when the output warrants
// attention.
//
// Settings live inline on this plugin's entry in shell.json:
//   { "id": "cheapseatsecon.laya-attention",
//     "intervalMs": 10000,
//     "threshold": 0.45 }
//
// The bar widget reads the exposed properties: lastTransitions, lastNotified,
// agentCount, layaUp, lastDecision.
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "cheapseatsecon.laya-attention"
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string python: home + "/.local/share/laya/.venv/bin/python"
  readonly property string pluginDir: {
    // The plugin is cloned into ~/.config/omarchy/plugins/<id>.
    var d = (manifest && manifest.__dir) ? String(manifest.__dir) : ""
    return d || (home + "/.config/omarchy/plugins/" + pluginId)
  }

  // ------------------------------------------------------------- settings

  property var settings: ({})
  readonly property int intervalMs: (settings.intervalMs | 0) || 10000
  readonly property real threshold: settings.threshold !== undefined ? Number(settings.threshold) : 0.45
  readonly property bool triageEnabled: settings.triageEnabled !== undefined ? !!settings.triageEnabled : true
  readonly property real triageThreshold: settings.triageThreshold !== undefined ? Number(settings.triageThreshold) : 0.6

  function parseSettings(raw) {
    var cfg = null
    try { cfg = JSON.parse(raw || "{}") } catch (e) { return {} }
    var entries = Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e && String(e.id || "") === service.pluginId) {
        var next = {}
        for (var k in e) next[k] = e[k]
        service.settings = next
        return next
      }
    }
    service.settings = {}
    return {}
  }

  property var pendingKeys: []  // keys with a persist not yet confirmed by shell.json

  function applySettings(s) {
    if (!s) return
    var prevTriage = service.triageEnabled
    var prevThreshold = service.triageThreshold
    // Carry forward in-memory values for keys whose persist has not landed
    // in shell.json yet — otherwise a stale-file reload reverts the panel.
    var merged = {}
    for (var k in s) merged[k] = s[k]
    for (var j = 0; j < service.pendingKeys.length; j++) {
      var pk = service.pendingKeys[j]
      if (pk in service.settings) merged[pk] = service.settings[pk]
    }
    service.settings = merged
    pollTimer.interval = service.intervalMs
    if (service.triageEnabled !== prevTriage || service.triageThreshold !== prevThreshold)
      applyTriageSettings()
  }

  // ------------------------------------------------------------- state

  property int lastTransitions: 0
  property int lastNotified: 0
  property int agentCount: 0
  property bool layaUp: false
  property string lastDecision: ""
  property int attentionAgents: 0
  property bool pollRunning: false

  // Triage (desktop notification suppression)
  property int triageSuppressed: 0
  property string lastTriage: ""

  // The triage watcher is a resident child: inotify on the notification
  // popup dir, classify each new popup through laya, close it via D-Bus
  // when it is routine progress/info. Restarted when triageEnabled or the
  // threshold changes.
  Process {
    id: triageProc
    stdout: StdioCollector { onRead: function (line) { if (line.indexOf("suppressed") !== -1) service.triageSuppressed++ } }
    onRunningChanged: function (running) {
      if (!running && service.triageEnabled) triageRestartTimer.restart()
    }
  }

  Timer {
    id: triageRestartTimer
    interval: 3000
    onTriggered: service.startTriage()
  }

  function startTriage() {
    if (!service.triageEnabled) return
    triageProc.command = [
      service.python,
      service.pluginDir + "/lib/triage.py",
      "--threshold", String(service.triageThreshold)
    ]
    // triage.py kills any stale watcher from its pidfile on startup.
    triageProc.running = false
    triageProc.running = true
  }

  function stopTriage() {
    triageRestartTimer.stop()
    triageProc.running = false
  }

  function applyTriageSettings() {
    if (service.triageEnabled) {
      // Restart to pick up a new threshold.
      if (triageProc.running) {
        triageProc.running = false
        triageRestartTimer.restart()
      } else {
        startTriage()
      }
    } else {
      stopTriage()
    }
  }

  // -------------------------------------------------- settings persistence

  property var persistQueue: []

  // Live edit of one setting from the panel: mutate, apply side effects,
  // and persist. applySettings() later confirms from shell.json (the FileView
  // reload after persist) and is a no-op when values already match.
  function applySetting(key, value) {
    var next = {}
    for (var k in service.settings) next[k] = service.settings[k]
    next[key] = value
    service.settings = next
    if (key === "intervalMs") pollTimer.interval = service.intervalMs
    if (key === "triageEnabled" || key === "triageThreshold") applyTriageSettings()
  }

  function persistSetting(patch) {
    var parsed = JSON.parse(patch)
    for (var k in parsed) {
      if (service.pendingKeys.indexOf(k) === -1) service.pendingKeys = service.pendingKeys.concat([k])
    }
    var snapshot = JSON.stringify(patch)
    service.persistQueue = service.persistQueue.concat([snapshot])
    service.persistNextSettings()
  }

  function persistSettings() {
    var snapshot = JSON.stringify({
      threshold: service.threshold,
      triageEnabled: service.triageEnabled,
      triageThreshold: service.triageThreshold
    })
    service.persistQueue = service.persistQueue.concat([snapshot])
    service.persistNextSettings()
  }

  function persistNextSettings() {
    if (persistProc.running || service.persistQueue.length === 0) return
    var snapshot = service.persistQueue[0]
    service.persistQueue = service.persistQueue.slice(1)
    var script = service.pluginDir + "/bin/omarchy-laya-attention-persist"
    persistProc.command = ["bash", script, service.pluginId, snapshot]
    persistProc.running = true
  }

  Process {
    id: persistProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: {
      service.persistNextSettings()
      // The persist script rewrites shell.json via mv (new inode); the
      // FileView watch may not fire across the rename, so re-read here.
      shellFile.reload()
      // The reload just read the file containing this patch, so its keys
      // are confirmed; clear the carry-forward set.
      service.pendingKeys = []
    }
  }

  // ------------------------------------------------------------- poll loop

  Process {
    id: pollProc
    stdout: StdioCollector { id: pollOut; waitForEnd: true }
    onExited: function (code) {
      service.pollRunning = false
      if (code === 0) {
        try {
          var d = JSON.parse(pollOut.text.trim() || "{}")
          service.lastTransitions = d.transitions | 0
          service.lastNotified = d.notified | 0
          var n = 0
          for (var k in d.agents || {}) n++
          service.agentCount = n
        } catch (e) {}
      }
      service.checkLaya()
      pollTimer.restart()
    }
  }

  function poll() {
    if (service.pollRunning) { pollTimer.restart(); return }
    service.pollRunning = true
    pollProc.command = [
      service.python,
      service.pluginDir + "/lib/poll.py",
      "--threshold", String(service.threshold)
    ]
    pollProc.running = true
  }

  // Liveness probe of the decision server, on the same interval.
  Process {
    id: pingProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function (code) { service.layaUp = (code === 0) }
  }

  function checkLaya() {
    pingProc.command = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        "--max-time", "3", "-X", "POST", "http://127.0.0.1:8000/v1/systemone",
                        "-H", "Content-Type: application/json",
                        "-d", JSON.stringify({ state: "ping", questions: { k: { type: "noul", instructions: "live check" } } })]
    pingProc.running = true
  }

  // The decision log records every classification; surface the last
  // attention-worthy one for the widget tooltip and click action.
  FileView {
    id: decisionsFile
    path: (Quickshell.env("XDG_STATE_HOME") || (service.home + "/.local/state")) + "/laya-attention/decisions.jsonl"
    watchChanges: true
    printErrors: false
    onLoaded: service.parseDecisions(text())
    onFileChanged: reload()
  }

  function parseDecisions(raw) {
    var lines = (raw || "").trim().split("\n").filter(Boolean)
    var lastByPane = {}
    for (var i = 0; i < lines.length; i++) {
      try {
        var d = JSON.parse(lines[i])
        lastByPane[d.pane] = d
      } catch (e) {}
    }
    var flagged = 0
    for (var pane in lastByPane) {
      if (lastByPane[pane].action === "notified") flagged++
    }
    service.attentionAgents = flagged
    // Most recent decision wins for the tooltip/click text.
    for (var j = lines.length - 1; j >= 0; j--) {
      try {
        var e = JSON.parse(lines[j])
        if (e.action === "notified") {
          service.lastDecision = (e.agent || e.pane) + " — " + e.kind + " (" + Number(e.prob).toFixed(2) + ")"
          return
        }
      } catch (e2) {}
    }
  }

  Timer {
    id: pollTimer
    interval: service.intervalMs
    repeat: false
    onTriggered: service.poll()
  }

  Component.onCompleted: {
    shellFile.reload()
    poll()
    startTriage()
  }

  // ------------------------------------------------------------- settings file

  FileView {
    id: shellFile
    path: service.configPath
    watchChanges: true
    printErrors: false
    onLoaded: service.applySettings(service.parseSettings(text()))
    onFileChanged: reload()
  }
}
