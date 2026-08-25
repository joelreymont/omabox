import QtQuick 2.15
import QtTest 1.0
import ".."

TestCase {
  name: "OmaboxStatus"

  Status {
    id: status
    autoRefreshSettings: false
  }

  Status {
    id: processFailureStatus
    autoRefreshSettings: false
  }

  Status {
    id: rootRefreshStatus
    autoRefreshSettings: false
  }

  Status {
    id: severityStatus
    autoRefreshSettings: false
  }

  function test_normalizes_concurrent_transfers() {
    var snapshot = status.normalize(JSON.stringify({
      version: 2,
      phase: "syncing",
      transfers: [
        { direction: "download", path: "/one", bytes_done: 10, bytes_total: 20 },
        { direction: "upload", path: "/two", bytes_done: 30, bytes_total: null }
      ],
      last_error: null,
      updated_at: 42
    }))

    verify(snapshot !== null)
    compare(snapshot.transfers.length, 2)
    compare(snapshot.transfers[1].direction, "upload")
  }

  function test_settings_require_an_absolute_sync_root() {
    compare(status.normalizeSettings('{"sync_root":"/home/test/Dropbox"}').sync_root,
      "/home/test/Dropbox")
    compare(status.normalizeSettings('{"sync_root":"relative"}'), null)
    compare(status.normalizeSettings('{"dropbox_app_key":"public"}'), null)
    compare(status.normalizeSettings('not json'), null)
  }

  function test_folder_urls_round_trip_without_a_shell() {
    var path = "/home/test/Dropbox folder/#notes"
    compare(status.localPathFromFolderUrl(status.folderUrlForPath(path)), path)
    compare(status.localPathFromFolderUrl("https://example.com/folder"), "")
  }

  function test_process_start_failures_clear_busy_state() {
    processFailureStatus.settingsPending = true
    processFailureStatus.settingsStoppedWithoutExit()
    verify(!processFailureStatus.settingsPending)
    verify(processFailureStatus.settingsError.indexOf("available in PATH") >= 0)

    processFailureStatus.actionKind = "restart"
    processFailureStatus.actionPending = true
    processFailureStatus.actionStoppedWithoutExit()
    verify(!processFailureStatus.actionPending)
    verify(!processFailureStatus.commandBusy)
    verify(processFailureStatus.actionError.indexOf("available in PATH") >= 0)
  }

  function test_failed_root_change_refreshes_settings_and_keeps_error() {
    rootRefreshStatus.applyActionResult("set-root", 1, "", "Restart failed after update.")
    compare(rootRefreshStatus.actionError, "Restart failed after update.")
    verify(rootRefreshStatus.settingsPending)
    verify(rootRefreshStatus.commandBusy)
  }

  function test_action_results_keep_cli_errors_actionable() {
    var success = status.actionResult("restart", 0, "", "")
    verify(success.ok)
    compare(success.message, "Service restarted.")

    var failure = status.actionResult("set-root", 1, "", "Wait for sync, then retry.\n")
    verify(!failure.ok)
    compare(failure.error, "Wait for sync, then retry.")
  }

  function test_bandwidth_history_is_bounded_and_in_memory() {
    var history = []
    for (var index = 1; index <= 35; index += 1)
      history = status.appendSpeed(history, index, 30)

    compare(history.length, 30)
    compare(history[0], 6)
    compare(history[29], 35)
    compare(status.appendSpeed(history, -1, 30)[29], 0)
  }

  function test_staleness_is_not_an_error() {
    severityStatus.apply(JSON.stringify({
      version: 2,
      phase: "waiting",
      transfers: [],
      last_error: null,
      updated_at: 100
    }))
    severityStatus.nowMs = (100 + 5 * 60 * 60) * 1000

    verify(severityStatus.stale)
    verify(!severityStatus.hasError)

    severityStatus.apply("not json")
    verify(severityStatus.hasError)
  }
}
