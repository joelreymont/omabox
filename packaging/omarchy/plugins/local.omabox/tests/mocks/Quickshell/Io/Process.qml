import QtQml

QtObject {
  property bool running: false
  property var command: []
  property var stdout: null
  property var stderr: null

  signal started()
  signal exited(int exitCode)
}
