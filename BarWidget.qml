import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.librael-the-culprit.simple-start-menu"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("pluginRegistry" in target)
      target.pluginRegistry = root.bar && root.bar.shell ? root.bar.shell.pluginRegistry : null
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("refresh" in target) Qt.callLater(target.refresh)
  }

  function toggle() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }
  function open()   { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
  function close()  { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function ping()   { return "ok" }
  function refresh() { if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\ue900"
    fontFamily: "omarchy"
    tooltipText: "Simple Start Menu"
    active: root.opened
    useActiveColor: true
    activeColor: Color.accent

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        root.bar.run("xdg-terminal-exec")
        return
      }
      root.toggle()
    }
  }
}