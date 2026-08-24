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
  readonly property int speedWindowMs: 1000

  readonly property bool ready: availability === "ready" && snapshot !== null
  readonly property bool stale: ready && nowMs / 1000 - snapshot.updated_at > 75
  readonly property var transfers: ready ? snapshot.transfers : []
  readonly property var transfer: transfers.length > 0 ? transfers[0] : null
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
