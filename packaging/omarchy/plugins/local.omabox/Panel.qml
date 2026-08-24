import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Dialogs
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "local.omabox"
  ipcTarget: "local.omabox"

  property string pendingSyncRoot: ""
  property bool cursorActive: false
  property int actionIndex: 1

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var snapshot: status.snapshot
  readonly property var transfers: status.transfers
  readonly property bool rootConfirmationOpen: pendingSyncRoot !== ""
  readonly property bool alerting: status.availability === "malformed" || status.stale
    || (snapshot && snapshot.phase === "error")
  readonly property bool inactive: status.stoppedByPanel || status.availability === "missing" || status.stale
    || (snapshot && snapshot.phase === "backoff")
  readonly property color stateColor: alerting ? urgent : (inactive ? dim : foreground)
  readonly property string stateTitle: titleForState()
  readonly property string stateDetail: detailForState()

  function titleForState() {
    if (status.stoppedByPanel) return "Service stopped"
    if (status.availability === "missing") return "Service stopped"
    if (status.availability === "malformed") return "Status unavailable"
    if (status.stale) return "Service not updating"
    if (!snapshot) return "Unavailable"
    if (snapshot.phase === "error") return "Sync error"
    if (snapshot.phase === "backoff") return "Waiting to retry"
    if (snapshot.phase === "starting") return "Starting"
    if (snapshot.phase === "syncing" && transfers.length > 0)
      return "Syncing " + transfers.length + (transfers.length === 1 ? " file" : " files")
    if (snapshot.phase === "syncing") return "Syncing"
    return "Up to date"
  }

  function detailForState() {
    if (status.stoppedByPanel) return "Start the service to resume syncing."
    if (status.availability === "missing") return "Omabox has not published a status snapshot."
    if (status.availability === "malformed") return "Omabox published an unreadable status snapshot."
    if (status.stale) return "Last update " + relativeTime(snapshot.updated_at) + "."
    if (snapshot && snapshot.last_error) return String(snapshot.last_error)
    if (snapshot && snapshot.phase === "backoff") return "Dropbox requested a short delay."
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

  function progressText(transfer) {
    if (!transfer) return ""
    if (transfer.bytes_total === null || transfer.bytes_total <= 0)
      return formatBytes(transfer.bytes_done) + " · percent unknown"
    var percent = Math.max(0, Math.min(100,
      Math.round(transfer.bytes_done / transfer.bytes_total * 100)))
    return formatBytes(transfer.bytes_done) + " of " + formatBytes(transfer.bytes_total)
      + " · " + percent + "%"
  }

  function aggregateProgressText() {
    if (transfers.length === 0) return ""
    if (status.aggregateBytesTotal === null || status.aggregateBytesTotal <= 0)
      return formatBytes(status.aggregateBytesDone) + " · total unknown"
    return formatBytes(status.aggregateBytesDone) + " of "
      + formatBytes(status.aggregateBytesTotal) + " · "
      + Math.round(status.aggregateFraction * 100) + "%"
  }

  function transferHeading() {
    if (transfers.length === 0) return "TRANSFERS"
    var direction = transfers[0].direction
    for (var index = 1; index < transfers.length; index += 1) {
      if (transfers[index].direction !== direction)
        return "SYNCING " + transfers.length + " FILES"
    }
    var action = direction === "upload" ? "UPLOADING" : "DOWNLOADING"
    return action + (transfers.length === 1 ? "" : " " + transfers.length + " FILES")
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

  function chooseSyncRoot() {
    if (status.settingsAvailability !== "ready" || status.commandBusy) return
    folderDialog.currentFolder = status.folderUrlForPath(status.syncRoot)
    folderDialog.open()
  }

  function offerSyncRoot(path) {
    root.open()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (path === "") return
    pendingSyncRoot = path
    rootConfirm.selectedIndex = 1
  }

  function cancelSyncRoot() {
    pendingSyncRoot = ""
  }

  function applySyncRoot() {
    var selected = pendingSyncRoot
    pendingSyncRoot = ""
    status.setSyncRoot(selected)
  }

  function firstActionIndex() {
    return status.settingsAvailability === "ready" ? 0 : 1
  }

  function ensureActionCursor() {
    actionIndex = Math.max(firstActionIndex(), Math.min(5, actionIndex))
  }

  function actionItem(index) {
    if (index === 0) return chooseFolderButton
    if (index === 1) return startButton
    if (index === 2) return stopButton
    if (index === 3) return restartButton
    if (index === 4) return setupHelpButton
    return logsButton
  }

  function scrollActionIntoView(item) {
    if (!item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maximum = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin)
        panelFlick.contentY = Math.min(maximum, bottom + margin - panelFlick.height)
    })
  }

  function setActionCursor(index) {
    cursorActive = true
    actionIndex = Math.max(firstActionIndex(), Math.min(5, index))
    scrollActionIntoView(actionItem(actionIndex))
  }

  function moveActionCursor(dx, dy) {
    if (!cursorActive) {
      setActionCursor(actionIndex)
      return
    }
    var delta = dy !== 0 ? dy : dx
    if (delta !== 0) setActionCursor(actionIndex + (delta > 0 ? 1 : -1))
  }

  function activateAction() {
    ensureActionCursor()
    var item = actionItem(actionIndex)
    if (item && item.visible && item.enabled) item.clicked()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onOpenedChanged: if (opened) {
    cursorActive = false
    ensureActionCursor()
    panelFlick.contentY = 0
    status.refreshSettings()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Status { id: status }

  Connections {
    target: status
    function onSettingsAvailabilityChanged() { root.ensureActionCursor() }
  }

  FolderDialog {
    id: folderDialog
    title: "Choose the Omabox sync folder"
    onAccepted: root.offerSyncRoot(status.localPathFromFolderUrl(selectedFolder))
    onRejected: root.offerSyncRoot("")
  }

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
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.rootConfirmationOpen && (dx !== 0 || dy !== 0))
          rootConfirm.selectedIndex = rootConfirm.selectedIndex === 0 ? 1 : 0
        else if (!root.rootConfirmationOpen) root.moveActionCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.rootConfirmationOpen) {
          if (rootConfirm.selectedIndex === 0) root.cancelSyncRoot()
          else root.applySyncRoot()
        } else {
          root.activateAction()
        }
      }
      onCloseRequested: {
        if (root.rootConfirmationOpen) root.cancelSyncRoot()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.rootConfirmationOpen)
          rootConfirm.selectedIndex = rootConfirm.selectedIndex === 0 ? 1 : 0
        else root.switchPanel(direction)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
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
            color: root.alerting ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            visible: status.actionError !== "" || status.actionMessage !== ""
            width: parent.width
            text: status.actionError !== "" ? status.actionError : status.actionMessage
            color: status.actionError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Column {
            visible: root.transfers.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: root.transferHeading()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            InfoPair { label: "Progress"; value: root.aggregateProgressText() }
            InfoPair { label: "Speed"; value: root.formatBytes(status.speedBytesPerSecond) + "/s" }

            Item {
              visible: status.aggregateBytesTotal !== null && status.aggregateBytesTotal > 0
              width: parent.width
              height: Style.space(4)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: root.dim
                opacity: 0.35
              }
              Rectangle {
                width: parent.width * status.aggregateFraction
                height: parent.height
                radius: height / 2
                color: root.stateColor
                Behavior on width {
                  NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }
              }
            }

            BandwidthChart {
              visible: status.speedHistory.length > 1
              width: parent.width
              samples: status.speedHistory
              capacity: status.speedHistoryCapacity
              lineColor: root.stateColor
            }

            Repeater {
              model: root.transfers

              delegate: Column {
                required property var modelData
                width: content.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: parent.modelData.path
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.WrapAnywhere
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: (parent.modelData.direction === "upload" ? "Upload · " : "Download · ")
                    + root.progressText(parent.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader {
            text: "SYNC FOLDER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          InfoPair {
            label: "Current"
            value: status.settingsAvailability === "checking" ? "Checking…"
              : (status.settingsAvailability === "ready" ? status.syncRoot : "Not configured")
          }
          Text {
            visible: status.settingsError !== ""
            width: parent.width
            text: status.settingsError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Button {
            id: chooseFolderButton
            visible: status.settingsAvailability === "ready"
            width: parent.width
            text: "Choose folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: !status.commandBusy
            hasCursor: root.cursorActive && root.actionIndex === 0
            onHovered: function(isHovered) { if (isHovered) root.setActionCursor(0) }
            onClicked: root.chooseSyncRoot()
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader {
            text: "SERVICE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Row {
            id: serviceButtons
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: startButton
              width: (serviceButtons.width - serviceButtons.spacing * 2) / 3
              text: "Start"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !status.commandBusy
              hasCursor: root.cursorActive && root.actionIndex === 1
              onHovered: function(isHovered) { if (isHovered) root.setActionCursor(1) }
              onClicked: status.controlService("start")
            }
            Button {
              id: stopButton
              width: (serviceButtons.width - serviceButtons.spacing * 2) / 3
              text: "Stop"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !status.commandBusy
              hasCursor: root.cursorActive && root.actionIndex === 2
              onHovered: function(isHovered) { if (isHovered) root.setActionCursor(2) }
              onClicked: status.controlService("stop")
            }
            Button {
              id: restartButton
              width: (serviceButtons.width - serviceButtons.spacing * 2) / 3
              text: "Restart"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !status.commandBusy
              hasCursor: root.cursorActive && root.actionIndex === 3
              onHovered: function(isHovered) { if (isHovered) root.setActionCursor(3) }
              onClicked: status.controlService("restart")
            }
          }

          Row {
            id: supportButtons
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: setupHelpButton
              width: (supportButtons.width - supportButtons.spacing) / 2
              text: "Setup help"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.actionIndex === 4
              onHovered: function(isHovered) { if (isHovered) root.setActionCursor(4) }
              onClicked: { root.close(); status.openSetupHelp() }
            }
            Button {
              id: logsButton
              width: (supportButtons.width - supportButtons.spacing) / 2
              text: "Logs"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.actionIndex === 5
              onHovered: function(isHovered) { if (isHovered) root.setActionCursor(5) }
              onClicked: { root.close(); status.openLogs() }
            }
          }
        }
      }

      ConfirmDialog {
        id: rootConfirm
        anchors.fill: parent
        opened: root.rootConfirmationOpen
        z: 10
        message: "Change the Omabox sync folder to “" + root.pendingSyncRoot
          + "”? The service will restart when the change is safe."
        confirmText: "Change"
        background: Color.background
        foreground: root.foreground
        scrim: Util.alpha(Color.background, 0.72)
        selectedBackground: Util.alpha(root.foreground, 0.08)
        selectedText: Color.accent
        fontFamily: root.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: root.cancelSyncRoot()
        onConfirmed: root.applySyncRoot()
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: pairLabel
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - parent.spacing)
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }

  component BandwidthChart: Item {
    id: chart
    property var samples: []
    property int capacity: 30
    property color lineColor: root.foreground
    readonly property real maximum: {
      var peak = 0
      for (var index = 0; index < samples.length; index += 1)
        peak = Math.max(peak, Number(samples[index] || 0))
      return peak
    }

    implicitHeight: Style.space(50)

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(root.foreground, 0.04)
      radius: Style.cornerRadius
    }

    Text {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      text: root.formatBytes(chart.maximum) + "/s peak · 30s"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Canvas {
      id: sparkline
      anchors.fill: parent
      anchors.topMargin: Style.space(15)
      anchors.rightMargin: Style.space(3)
      anchors.bottomMargin: Style.space(3)
      anchors.leftMargin: Style.space(3)

      onPaint: {
        var context = getContext("2d")
        context.clearRect(0, 0, width, height)
        if (chart.samples.length < 2) return
        var scale = Math.max(1, chart.maximum)
        var slots = Math.max(2, chart.capacity)
        var offset = Math.max(0, slots - chart.samples.length)
        context.beginPath()
        for (var index = 0; index < chart.samples.length; index += 1) {
          var x = (offset + index) / (slots - 1) * width
          var y = height - Math.max(0, Number(chart.samples[index] || 0)) / scale * height
          if (index === 0) context.moveTo(x, y)
          else context.lineTo(x, y)
        }
        context.strokeStyle = chart.lineColor
        context.lineWidth = Math.max(1, Style.normalBorderWidth)
        context.stroke()
      }

      Connections {
        target: chart
        function onSamplesChanged() { sparkline.requestPaint() }
        function onLineColorChanged() { sparkline.requestPaint() }
      }
    }
  }
}
