import QtQuick
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "local.omabox"
  ipcTarget: "local.omabox"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var snapshot: status.snapshot
  readonly property var transfer: status.transfer
  readonly property var counts: snapshot ? snapshot.counts : ({ queued: 0, blocked: 0, conflicts: 0 })
  readonly property bool needsAttention: status.availability === "malformed" || status.stale
    || (snapshot && (snapshot.phase === "error" || snapshot.phase === "blocked"))
    || counts.blocked > 0 || counts.conflicts > 0
  readonly property bool inactive: status.availability === "missing" || status.stale
    || (snapshot && snapshot.phase === "backoff")
  readonly property color stateColor: needsAttention ? urgent : (inactive ? dim : foreground)
  readonly property string stateTitle: titleForState()
  readonly property string stateDetail: detailForState()

  function titleForState() {
    if (status.availability === "missing") return "Service stopped"
    if (status.availability === "malformed") return "Status unavailable"
    if (status.stale) return "Service not updating"
    if (!snapshot) return "Unavailable"
    if (snapshot.phase === "starting") return "Starting"
    if (snapshot.phase === "syncing") return "Syncing"
    if (snapshot.phase === "waiting") return "Up to date"
    if (snapshot.phase === "backoff") return "Offline · retrying"
    if (snapshot.phase === "blocked") return "Sync blocked"
    return "Sync error"
  }

  function detailForState() {
    if (status.availability === "missing") return "Omabox has not published a status snapshot."
    if (status.availability === "malformed") return "Omabox published an unreadable status snapshot."
    if (status.stale) return "Last update " + relativeTime(snapshot.updated_at) + "."
    if (snapshot && snapshot.last_error) return String(snapshot.last_error)
    if (snapshot && snapshot.phase === "backoff") return "Waiting to reconnect to Dropbox."
    return ""
  }

  function formatBytes(bytes) {
    var value = Number(bytes || 0)
    if (!isFinite(value) || value <= 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var index = 0
    while (value >= 1000 && index < units.length - 1) {
      value /= 1000
      index += 1
    }
    var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
    return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
  }

  function progressText() {
    if (!transfer) return ""
    if (transfer.bytes_total === null || transfer.bytes_total <= 0)
      return formatBytes(transfer.bytes_done) + " · percent unknown"
    var percent = Math.max(0, Math.min(100,
      Math.round(transfer.bytes_done / transfer.bytes_total * 100)))
    return formatBytes(transfer.bytes_done) + " of " + formatBytes(transfer.bytes_total)
      + " · " + percent + "%"
  }

  function relativeTime(timestamp) {
    var seconds = Number(timestamp || 0)
    if (!(seconds > 0)) return "Never"
    var age = Math.max(0, Math.floor(status.nowMs / 1000 - seconds))
    if (age < 10) return "Just now"
    if (age < 60) return age + "s ago"
    var minutes = Math.floor(age / 60)
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onOpenedChanged: if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  Status { id: status }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.snapshot && root.snapshot.phase === "syncing" ? "󰓦" : ""
    foreground: root.stateColor
    tooltipText: root.stateTitle
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Omabox"
            meta: root.stateTitle
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.inactive ? 0.55 : 1
            iconComponent: Component {
              Text {
                text: ""
                color: root.stateColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.stateDetail !== ""
            width: parent.width
            text: root.stateDetail
            color: root.needsAttention ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Column {
            visible: root.transfer !== null
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: root.transfer && root.transfer.direction === "upload" ? "UPLOADING" : "DOWNLOADING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              text: root.transfer ? root.transfer.path : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 3
              elide: Text.ElideRight
            }
            InfoPair { label: "Progress"; value: root.progressText() }
            InfoPair { label: "Speed"; value: root.formatBytes(status.speedBytesPerSecond) + "/s" }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader {
            text: "SYNC STATUS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          InfoPair { label: "Queued"; value: String(root.counts.queued) }
          InfoPair { label: "Blocked"; value: String(root.counts.blocked); alarming: root.counts.blocked > 0 }
          InfoPair { label: "Conflicts"; value: String(root.counts.conflicts); alarming: root.counts.conflicts > 0 }
          InfoPair {
            label: "Last successful sync"
            value: root.snapshot ? root.relativeTime(root.snapshot.last_successful_pass) : "Unavailable"
          }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property bool alarming: false

    width: parent.width
    spacing: Style.space(8)

    Text {
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth
        - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      text: value
      color: alarming ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: alarming
      elide: Text.ElideRight
    }
  }
}
