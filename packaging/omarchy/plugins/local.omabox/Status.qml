import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string statusPath: runtimeDir === ""
    ? "/dev/null/omabox/status.json" : runtimeDir + "/omabox/status.json"
  property string availability: "missing"
  property var snapshot: null
  property double nowMs: Date.now()
  property real measuredSpeed: 0
  property double speedMeasuredAtMs: 0
  property double speedWindowStartedAtMs: 0
  property string speedIdentity: ""
  property var speedBaseline: ({})
  property var latestSamples: ({})
  property var speedHistory: []
  property string settingsAvailability: "checking"
  property string syncRoot: ""
  property string settingsError: ""
  property string actionMessage: ""
  property string actionError: ""
  property bool autoRefreshSettings: true
  property string actionKind: ""
  property string settingsOutput: ""
  property string settingsProcessError: ""
  property string actionOutput: ""
  property string actionProcessError: ""
  property bool settingsPending: false
  property bool actionPending: false
  property bool stoppedByPanel: false
  property double stoppedAt: 0
  readonly property int speedWindowMs: 1000
  readonly property int speedHistoryCapacity: 30
  readonly property bool commandBusy: settingsPending || actionPending
    || settingsProcess.running || actionProcess.running

  readonly property bool ready: availability === "ready" && snapshot !== null
  readonly property bool stale: ready && nowMs / 1000 - snapshot.updated_at > 75
  readonly property var transfers: ready ? snapshot.transfers : []
  readonly property real aggregateBytesDone: {
    var total = 0
    for (var index = 0; index < transfers.length; index += 1)
      total += transfers[index].bytes_done
    return total
  }
  readonly property var aggregateBytesTotal: {
    if (transfers.length === 0) return null
    var total = 0
    for (var index = 0; index < transfers.length; index += 1) {
      if (transfers[index].bytes_total === null) return null
      total += transfers[index].bytes_total
    }
    return total
  }
  readonly property real aggregateFraction: aggregateBytesTotal > 0
    ? Math.max(0, Math.min(1, aggregateBytesDone / aggregateBytesTotal)) : 0
  readonly property real speedBytesPerSecond: transfers.length > 0 && speedMeasuredAtMs > 0
    && nowMs - speedMeasuredAtMs <= 5000 ? measuredSpeed : 0

  function elideOutput(output, fallback) {
    var value = String(output || fallback || "").replace(/\s+/g, " ").trim()
    return value.length > 180 ? value.substring(0, 177) + "…" : value
  }

  function normalizeSettings(content) {
    var value
    try { value = JSON.parse(String(content || "")) }
    catch (error) { return null }
    if (!value || Array.isArray(value) || typeof value.sync_root !== "string"
        || value.sync_root.length === 0 || value.sync_root.charAt(0) !== "/") return null
    return { sync_root: value.sync_root }
  }

  function localPathFromFolderUrl(folder) {
    var value = String(folder || "")
    if (value.indexOf("file://localhost/") === 0) value = value.substring(16)
    else if (value.indexOf("file:///") === 0) value = value.substring(7)
    else return ""
    try { return decodeURIComponent(value) }
    catch (error) { return "" }
  }

  function folderUrlForPath(path) {
    var parts = String(path || "/").split("/")
    for (var index = 0; index < parts.length; index += 1)
      parts[index] = encodeURIComponent(parts[index])
    return "file://" + parts.join("/")
  }

  function applySettings(content) {
    var next = normalizeSettings(content)
    if (next === null) {
      settingsAvailability = "unavailable"
      syncRoot = ""
      settingsError = "Omabox returned unreadable settings."
      return false
    }
    settingsAvailability = "ready"
    syncRoot = next.sync_root
    settingsError = ""
    return true
  }

  function refreshSettings() {
    if (settingsPending || settingsProcess.running) return
    settingsOutput = ""
    settingsProcessError = ""
    settingsAvailability = syncRoot === "" ? "checking" : settingsAvailability
    settingsProcess.command = ["omabox", "settings", "--json"]
    settingsPending = true
    settingsProcess.running = true
  }

  function setSyncRoot(path) {
    if (commandBusy || typeof path !== "string" || path.length === 0) return
    actionKind = "set-root"
    actionOutput = ""
    actionProcessError = ""
    actionMessage = "Changing sync folder…"
    actionError = ""
    actionProcess.command = ["omabox", "settings", "set-root", path]
    actionPending = true
    actionProcess.running = true
  }

  function controlService(action) {
    if (commandBusy || ["start", "stop", "restart"].indexOf(action) < 0) return
    actionKind = action
    actionOutput = ""
    actionProcessError = ""
    actionMessage = action === "start" ? "Starting service…"
      : (action === "stop" ? "Stopping service…" : "Restarting service…")
    actionError = ""
    actionProcess.command = ["omabox", "service", action]
    actionPending = true
    actionProcess.running = true
  }

  function actionResult(kind, exitCode, stdout, stderr) {
    if (exitCode !== 0) {
      return {
        ok: false,
        message: "",
        error: elideOutput(stderr || stdout, "Omabox command failed.")
      }
    }
    var messages = {
      "set-root": "Sync folder changed.",
      "start": "Service started.",
      "stop": "Service stopped.",
      "restart": "Service restarted."
    }
    return { ok: true, message: messages[kind] || "Done.", error: "" }
  }

  function applyActionResult(kind, exitCode, stdout, stderr) {
    var result = actionResult(kind, exitCode, stdout, stderr)
    actionMessage = result.message
    actionError = result.error
    if (result.ok) {
      if (kind === "stop") {
        stoppedByPanel = true
        stoppedAt = Math.floor(Date.now() / 1000)
      } else if (kind === "start" || kind === "restart") {
        stoppedByPanel = false
      }
      actionMessageTimer.restart()
    }
    if (kind === "set-root") refreshSettings()
  }

  function settingsStoppedWithoutExit() {
    if (!settingsPending || settingsProcess.running) return
    settingsPending = false
    settingsAvailability = "unavailable"
    syncRoot = ""
    settingsError = "Omabox settings did not run to completion. Ensure omabox is installed and available in PATH, then retry."
  }

  function actionStoppedWithoutExit() {
    if (!actionPending || actionProcess.running) return
    var kind = actionKind
    actionPending = false
    actionMessage = ""
    actionError = "The Omabox command did not run to completion. Ensure omabox is installed and available in PATH, then retry."
    if (kind === "set-root") refreshSettings()
  }

  function openSetupHelp() {
    Quickshell.execDetached([
      "xdg-terminal-exec", "--title=Omabox setup", "--hold", "--", "omabox", "--help"
    ])
  }

  function openLogs() {
    Quickshell.execDetached([
      "xdg-terminal-exec", "--title=Omabox logs", "--hold", "--", "omabox", "logs"
    ])
  }

  function appendSpeed(history, value, capacity) {
    var next = Array.isArray(history) ? history.slice() : []
    var sample = Number(value)
    next.push(isFinite(sample) && sample > 0 ? sample : 0)
    if (next.length > capacity) next = next.slice(next.length - capacity)
    return next
  }

  function recordSpeed() {
    speedHistory = appendSpeed(speedHistory,
      ready && !stale ? speedBytesPerSecond : 0, speedHistoryCapacity)
  }

  function clearHistory() {
    speedHistory = []
  }

  function isCount(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
      && Math.floor(value) === value
  }

  function validTransfer(transfer) {
    return transfer && !Array.isArray(transfer)
      && ["upload", "download"].indexOf(transfer.direction) >= 0
      && typeof transfer.path === "string" && isCount(transfer.bytes_done)
      && (transfer.bytes_total === null || isCount(transfer.bytes_total))
  }

  function normalize(content) {
    var value
    try { value = JSON.parse(String(content || "")) }
    catch (error) { return null }

    var phases = ["starting", "syncing", "waiting", "backoff", "error"]
    if (!value || Array.isArray(value) || [1, 2].indexOf(value.version) < 0
        || phases.indexOf(value.phase) < 0
        || !isCount(value.updated_at) || value.updated_at === 0
        || (value.last_error !== null && typeof value.last_error !== "string")) return null

    var transfers
    if (value.version === 1) {
      if (value.transfer !== null && !validTransfer(value.transfer)) return null
      transfers = value.transfer === null ? [] : [value.transfer]
    } else {
      if (!Array.isArray(value.transfers)) return null
      transfers = value.transfers
      for (var index = 0; index < transfers.length; index += 1) {
        if (!validTransfer(transfers[index])) return null
      }
    }
    return {
      version: 2,
      phase: value.phase,
      transfers: transfers,
      last_error: value.last_error,
      updated_at: value.updated_at
    }
  }

  function clearSample() {
    speedWindowStartedAtMs = 0
    speedIdentity = ""
    speedBaseline = ({})
    latestSamples = ({})
    measuredSpeed = 0
    speedMeasuredAtMs = 0
  }

  function sampleTransfers(transfers, receivedAt) {
    var samples = ({})
    var identities = []
    for (var index = 0; index < transfers.length; index += 1) {
      var transfer = transfers[index]
      var key = transfer.direction + "\n" + transfer.path
      samples[key] = transfer.bytes_done
      identities.push([transfer.direction, transfer.path])
    }
    var identity = JSON.stringify(identities)
    if (identity !== speedIdentity) {
      speedIdentity = identity
      speedBaseline = samples
      latestSamples = samples
      speedWindowStartedAtMs = receivedAt
      measuredSpeed = 0
      speedMeasuredAtMs = 0
      return
    }

    var changed = false
    for (var sampleKey in samples) {
      if (samples[sampleKey] !== latestSamples[sampleKey]) {
        changed = true
        break
      }
    }
    latestSamples = samples
    if (!changed || receivedAt - speedWindowStartedAtMs < speedWindowMs) return

    var delta = 0
    for (var key in samples) {
      var baseline = speedBaseline[key]
      if (typeof baseline !== "number" || samples[key] < baseline) {
        speedBaseline = samples
        speedWindowStartedAtMs = receivedAt
        measuredSpeed = 0
        speedMeasuredAtMs = 0
        return
      }
      delta += samples[key] - baseline
    }
    var elapsed = (receivedAt - speedWindowStartedAtMs) / 1000
    measuredSpeed = elapsed > 0 ? delta / elapsed : 0
    speedMeasuredAtMs = receivedAt
    speedBaseline = samples
    speedWindowStartedAtMs = receivedAt
  }

  function apply(content) {
    var next = normalize(content)
    if (next === null) {
      availability = "malformed"
      snapshot = null
      clearSample()
      clearHistory()
      return
    }

    var receivedAt = Date.now()
    var current = next.transfers
    if (current.length === 0) {
      clearSample()
    } else {
      sampleTransfers(current, receivedAt)
    }

    snapshot = next
    availability = "ready"
    nowMs = receivedAt
    if (stoppedByPanel && next.updated_at > stoppedAt) stoppedByPanel = false
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
    onLoadFailed: {
      root.availability = "missing"
      root.snapshot = null
      root.clearSample()
      root.clearHistory()
    }
  }

  Process {
    id: settingsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: settingsStdout
      waitForEnd: true
      onStreamFinished: root.settingsOutput = text
    }
    stderr: StdioCollector {
      id: settingsStderr
      waitForEnd: true
      onStreamFinished: root.settingsProcessError = text
    }
    onExited: function(exitCode) {
      if (!root.settingsPending) return
      root.settingsPending = false
      var stdout = String(settingsStdout.text || root.settingsOutput || "")
      var stderr = String(settingsStderr.text || root.settingsProcessError || "")
      if (exitCode === 0) {
        root.applySettings(stdout)
        return
      }
      root.settingsAvailability = "unavailable"
      root.syncRoot = ""
      root.settingsError = root.elideOutput(stderr || stdout,
        "Could not read Omabox settings.")
    }
    onRunningChanged: if (!running && root.settingsPending) {
      Qt.callLater(function() { root.settingsStoppedWithoutExit() })
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
      onStreamFinished: root.actionOutput = text
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
      onStreamFinished: root.actionProcessError = text
    }
    onExited: function(exitCode) {
      if (!root.actionPending) return
      root.actionPending = false
      var stdout = String(actionStdout.text || root.actionOutput || "")
      var stderr = String(actionStderr.text || root.actionProcessError || "")
      root.applyActionResult(root.actionKind, exitCode, stdout, stderr)
    }
    onRunningChanged: if (!running && root.actionPending) {
      Qt.callLater(function() { root.actionStoppedWithoutExit() })
    }
  }

  Timer {
    id: actionMessageTimer
    interval: 3500
    repeat: false
    onTriggered: root.actionMessage = ""
  }

  Timer {
    property int ticks: 0
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.recordSpeed()
      if (++ticks >= 5) {
        ticks = 0
        statusFile.reload()
      }
    }
  }

  Component.onCompleted: if (autoRefreshSettings) refreshSettings()
}
