import QtQml

QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: false

  signal fileChanged()
  signal loaded()
  signal loadFailed()

  function reload() {}
  function text() { return "" }
}
