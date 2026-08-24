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
  property var previousSample: null

  readonly property bool ready: availability === "ready" && snapshot !== null
  readonly property bool stale: ready && nowMs / 1000 - snapshot.updated_at > 75
  readonly property var transfer: ready ? snapshot.transfer : null
  readonly property real speedBytesPerSecond: transfer && speedMeasuredAtMs > 0
    && nowMs - speedMeasuredAtMs <= 5000 ? measuredSpeed : 0

  function isCount(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
      && Math.floor(value) === value
  }

  function normalize(content) {
    var value
    try { value = JSON.parse(String(content || "")) }
    catch (error) { return null }

    var phases = ["starting", "syncing", "waiting", "backoff", "error"]
    if (!value || Array.isArray(value) || value.version !== 1
        || phases.indexOf(value.phase) < 0
        || !isCount(value.updated_at) || value.updated_at === 0
        || (value.last_error !== null && typeof value.last_error !== "string")) return null

    if (value.transfer !== null) {
      var transfer = value.transfer
      if (!transfer || Array.isArray(transfer)
          || ["upload", "download"].indexOf(transfer.direction) < 0
          || typeof transfer.path !== "string" || !isCount(transfer.bytes_done)
          || (transfer.bytes_total !== null && !isCount(transfer.bytes_total))) return null
    }
    return value
  }

  function clearSample() {
    previousSample = null
    measuredSpeed = 0
    speedMeasuredAtMs = 0
  }

  function apply(content) {
    var next = normalize(content)
    if (next === null) {
      availability = "malformed"
      snapshot = null
      clearSample()
      return
    }

    var receivedAt = Date.now()
    var current = next.transfer
    if (!current) {
      clearSample()
    } else {
      var key = current.direction + "\n" + current.path
      var changed = !previousSample || current.bytes_done !== previousSample.bytes
        || next.updated_at !== previousSample.updatedAt || key !== previousSample.key
      if (changed && previousSample && key === previousSample.key
          && current.bytes_done >= previousSample.bytes) {
        var elapsed = (receivedAt - previousSample.receivedAt) / 1000
        if (elapsed > 0) {
          measuredSpeed = (current.bytes_done - previousSample.bytes) / elapsed
          speedMeasuredAtMs = receivedAt
        }
      } else if (changed) {
        measuredSpeed = 0
        speedMeasuredAtMs = 0
      }
      if (changed) previousSample = {
        key: key, bytes: current.bytes_done,
        updatedAt: next.updated_at, receivedAt: receivedAt
      }
    }

    snapshot = next
    availability = "ready"
    nowMs = receivedAt
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
    }
  }

  Timer {
    property int ticks: 0
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      if (++ticks >= 5) {
        ticks = 0
        statusFile.reload()
      }
    }
  }
}
