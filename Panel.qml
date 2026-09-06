import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

// Start menu popup anchored to its bar button (Plasma Kickoff style).
//
// Layout:
//   header  - search field (owns its text natively, so Backspace/space work)
//   body    - left rail: Places
//             right pane: Pinned apps + omarchy-menu "Actions" sections with
//                         drilldown (scrollable), or search-result grid
//   footer  - transparency slider + session buttons
//
// The menu tree comes straight from omarchy-menu.jsonc, so the same sections
// the omarchy menu knows (Style, Install, Setup, Trigger, ...) are browsable
// here, with identical `when:`/`checked:` visibility guards.
//
// Right-click an app (grid cell, pinned row or Apps list) to pin/unpin it to
// the Pinned section. Pins and opacity persist under ~/.local/state/omarchy/startmenu.
Panel {
  id: root
  moduleName: "io.github.librael-the-culprit.simple-start-menu"
  ipcTarget: "io.github.librael-the-culprit.simple-start-menu"
  manageIpc: true

  // ---------------------------------------------------------------- injected

  property var anchorItem: null
  property var hostWidget: null
  property var pluginRegistry: null

  readonly property var barIdentity: hostWidget || root
  readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null

  property string menuDefaultPath: "/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
  property string menuUserPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/extensions/omarchy-menu.jsonc"

  // ---------------------------------------------------------------- theme

  readonly property color fg: Color.popups.text
  readonly property color muted: Color.muted
  readonly property color accent: Color.accent
  readonly property color border: Color.popups.border
  readonly property color cellHover: Color.menu.selectedBackground
  readonly property color cellText: Color.menu.text
  readonly property color baseCardColor: Color.popups.background

  readonly property int contentMargin: Style.spacing.popupPadding
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int searchHeight: Math.round(Style.spacing.controlHeight + Style.spacing.inputPaddingY * 2)
  readonly property int footerHeight: Math.round(Style.space(40))

  // ---------------------------------------------------------------- opacity

  property real cardOpacity: 1
  readonly property color cardFill: Qt.rgba(baseCardColor.r, baseCardColor.g, baseCardColor.b, baseCardColor.a * root.cardOpacity)

  readonly property string stateDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/startmenu"
  readonly property string statePath: root.stateDir + "/opacity"

  function applyOpacity(raw) {
    var t = String(raw == null ? "" : raw).trim()
    if (t === "") { root.cardOpacity = 1; return }
    var n = Number(t)
    if (isFinite(n)) root.cardOpacity = Math.max(0, Math.min(1, n))
  }

  function saveOpacity() {
    if (!root.bar || typeof root.bar.run !== "function") return
    root.bar.run("bash -lc 'mkdir -p \"$HOME/.local/state/omarchy/startmenu\" && printf %s " + root.cardOpacity.toFixed(3) + " > \"$HOME/.local/state/omarchy/startmenu/opacity\"'")
  }

  // ---------------------------------------------------------------- pinned

  property var pinned: []
  property var pinnedResolved: []

  readonly property string pinnedPath: root.stateDir + "/pinned"

  function isPinned(id) {
    return root.pinned.indexOf(String(id)) >= 0
  }

  function pin(id) {
    id = String(id)
    if (!id || root.isPinned(id)) return
    var next = root.pinned.slice()
    next.push(id)
    root.pinned = next
    root.rebuildPinned()
    root.savePinned()
  }

  function unpin(id) {
    id = String(id)
    var next = []
    for (var i = 0; i < root.pinned.length; i++)
      if (root.pinned[i] !== id) next.push(root.pinned[i])
    root.pinned = next
    root.rebuildPinned()
    root.rebuildBrowse()
    root.savePinned()
  }

  function savePinned() {
    if (!root.bar || typeof root.bar.run !== "function") return
    var list = ""
    for (var i = 0; i < root.pinned.length; i++) list += "\"" + root.pinned[i] + "\" "
    if (!list) list = "''"
    root.bar.run("bash -lc 'mkdir -p \"$HOME/.local/state/omarchy/startmenu\" && printf \"%s\\n\" " + list + " > \"$HOME/.local/state/omarchy/startmenu/pinned\"'")
  }

  function applyPinned(text) {
    var ids = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].trim()
      if (t) ids.push(t)
    }
    root.pinned = ids
    root.rebuildPinned()
  }

  function entryById(id) {
    id = String(id)
    if (!root.appLibrary || typeof root.appLibrary.sortedEntries !== "function") return null
    var rows = root.appLibrary.sortedEntries("") || []
    for (var i = 0; i < rows.length; i++) {
      var e = root.unwrap(rows[i])
      if (e && root.appId(e) === id) return e
    }
    return null
  }

  function rebuildPinned() {
    var out = []
    for (var i = 0; i < root.pinned.length; i++) {
      var e = root.entryById(root.pinned[i])
      if (e) out.push({ id: String(e.id), name: root.entryName(e), icon: String(e.icon || "") })
    }
    root.pinnedResolved = out
    root.rebuildBrowse()
  }

  // ---------------------------------------------------------------- session

  readonly property var powerActions: [
    { icon: "\uf023", label: "Lock",     cmd: "omarchy system lock" },
    { icon: "\uf2f1", label: "Restart",  cmd: "omarchy system reboot" },
    { icon: "\uf011", label: "Shutdown", cmd: "omarchy system shutdown" }
  ]

  property var places: []

  // ---------------------------------------------------------------- search

  property string searchText: ""
  property int gridIndex: 0

  function searching() {
    return String(root.searchText).trim().length > 0
  }

  // Focus the search field without trusting a compile-time id lookup: under a
  // partial plugin reload the id may resolve to nothing, and a bare call would
  // throw in the middle of an open/openSection/goBack navigation.
  function focusSearch() {
    var f = typeof searchField !== "undefined" ? searchField : null
    if (f) f.forceActiveFocus()
  }

  function unwrap(row) {
    while (row && typeof row === "object" && row.score !== undefined && row.entry && typeof row.entry === "object")
      row = row.entry
    return row
  }

  function appId(entry) {
    var e = root.unwrap(entry)
    var id = String(e && (e.id || e.desktopId) || "")
    if (root.appLibrary && typeof root.appLibrary.normalizeDesktopId === "function")
      return root.appLibrary.normalizeDesktopId(id)
    return id
  }

  function searchResults() {
    if (!root.searching() || !root.appLibrary || typeof root.appLibrary.sortedEntries !== "function") return []
    var rows = root.appLibrary.sortedEntries(root.searchText) || []
    var out = []
    var n = Math.min(24, rows.length)
    for (var i = 0; i < n; i++) {
      var e = root.unwrap(rows[i])
      if (e) out.push(e)
    }
    return out
  }

  function visibleApps() {
    return root.searchResults()
  }

  function entryName(entry) {
    var e = root.unwrap(entry)
    if (root.appLibrary && typeof root.appLibrary.entryName === "function")
      return root.appLibrary.entryName(e)
    return String(e && (e.name || e.id) || "")
  }

  function rowAppIcon(row) {
    if (!row) return ""
    var appIcon = String(row.appIcon || "")
    if (appIcon && root.appLibrary && typeof root.appLibrary.iconSource === "function")
      return root.appLibrary.iconSource(appIcon)
    var id = String(row.appId || "")
    if (id) {
      var e = root.entryById(id)
      if (e && String(e.icon || "")) return root.appLibrary.iconSource(String(e.icon || ""))
    }
    return ""
  }

  function iconSource(entry) {
    var e = root.unwrap(entry)
    if (root.appLibrary && typeof root.appLibrary.iconSource === "function")
      return root.appLibrary.iconSource(e ? String(e.icon || "") : "")
    return Quickshell.iconPath("application-x-executable", true)
  }

  function launchDesktop(entry) {
    var e = root.unwrap(entry)
    if (!e) return
    if (root.appLibrary && typeof root.appLibrary.launch === "function") {
      root.appLibrary.launch(e.id, root.entryName(e))
      root.close()
      return
    }
    var id = root.appId(e)
    if (id) {
      Quickshell.execDetached("gtk-launch " + id + ".desktop")
      root.close()
    }
  }

  function launchAppId(id) {
    var e = root.entryById(id)
    if (e) root.launchDesktop(e)
  }

  function moveCursor(dx, dy) {
    if (root.searching()) {
      var apps = root.searchResults()
      if (apps.length === 0) return
      var cols = root.gridColumns()
      var idx = root.gridIndex
      if (idx < 0 || idx >= apps.length) idx = 0
      var target = idx + dy * cols + dx
      if (target < 0) target = 0
      if (target >= apps.length) target = apps.length - 1
      root.gridIndex = target
      try { appGrid.positionViewAtIndex(target, GridView.Contain) } catch (err) {}
    } else {
      var rows = root.browseModel
      if (rows.length === 0) return
      var b = root.browseCursor
      if (b < 0 || b >= rows.length) b = 0
      var t2 = b + (dx + dy === 0 ? 1 : 0)
      if (dy > 0 || dx > 0) t2 = b + 1
      if (dy < 0 || dx < 0) t2 = b - 1
      if (t2 < 0) t2 = 0
      if (t2 >= rows.length) t2 = rows.length - 1
      if (rows[t2] && rows[t2]._header) t2 = t2 + (dy + dx > 0 ? 1 : -1)
      if (t2 < 0) t2 = 0
      if (t2 >= rows.length) t2 = rows.length - 1
      root.browseCursor = t2
      try { browseList.positionViewAtIndex(t2, ListView.Contain) } catch (err) {}
    }
  }

  function activateTarget() {
    if (root.searching()) {
      var apps = root.searchResults()
      if (apps.length === 0) return
      var idx = root.gridIndex
      if (idx < 0 || idx >= apps.length) idx = 0
      var e = root.unwrap(apps[idx])
      if (e) root.launchDesktop(e)
    } else {
      var rows = root.browseModel
      if (rows.length === 0) return
      var i = root.browseCursor
      if (i < 0 || i >= rows.length) i = 0
      var row = rows[i]
      if (!row || row._header) return
      root.activateBrowseRow(row)
      root.focusSearch()
    }
  }

  // ---------------------------------------------------------------- menu

  property var menuItems: ({})
  property var menuOrder: []
  property var sections: []
  property var whenResults: ({})
  property var checkedResults: ({})
  property var providerRows: ({})

  property string currentId: "root"
  property var stack: ["root"]
  property int browseCursor: 0
  property var browseModel: []

  function gridColumns() {
    var w = appGrid ? appGrid.width : 0
    if (w <= 0) return 4
    return Math.max(1, Math.round(w / Math.round(Style.space(110))))
  }

  function rebuildMenu() {
    var defaultItems = MenuModel.parseMenuJsonc(menuDefaultFile.text())
    var userItems = MenuModel.parseMenuJsonc(userMenuFile.text())
    var merged = MenuModel.mergeMenuSources(defaultItems, userItems)

    var appRows = root.allAppRows()
    if (appRows.length > 0)
      merged = MenuModel.mergeAppRows(merged.items, merged.itemOrder, appRows)

    root.menuItems = merged.items
    root.menuOrder = merged.itemOrder
    root.sections = []
    for (var i = 0; i < root.menuOrder.length; i++) {
      var e = root.menuItems[root.menuOrder[i]]
      if (e && e.parent === "root") root.sections.push(root.menuOrder[i])
    }
    root.stack = ["root"]
    root.currentId = "root"
    root.browseCursor = 0
    root.rebuildBrowse()
    root.evaluateGuards()
  }

  function allAppRows() {
    if (!root.appLibrary || typeof root.appLibrary.sortedEntries !== "function") return []
    var rows = root.appLibrary.sortedEntries("") || []
    var out = []
    var max = 150
    for (var i = 0; i < rows.length && out.length < max; i++) {
      var e = root.unwrap(rows[i])
      if (!e) continue
      var sub = root.appLibrary.entrySubtext ? root.appLibrary.entrySubtext(e) : ""
      out.push({
        id: "apps." + e.id,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: String(e.icon || ""),
        appId: String(e.id || ""),
        label: root.entryName(e),
        title: "",
        target: "",
        description: sub,
        action: "",
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }
    return out
  }

  function visibleSectionEligible(id) {
    var e = root.menuItems[id]
    if (!e) return false
    return MenuModel.isVisible(root.menuItems, root.menuOrder, root.whenResults, e)
  }

  function browseRows() {
    if (root.currentId === "apps") return root.allAppRows()
    if (root.currentId === "root") {
      var rows = []
      if (root.pinnedResolved.length > 0) {
        rows.push({ _header: "Pinned" })
        for (var p = 0; p < root.pinnedResolved.length; p++) {
          var pin = root.pinnedResolved[p]
          rows.push({ itemId: "pin." + pin.id, kind: "app", appId: pin.id, appIcon: pin.icon, label: pin.name, icon: "", _pinned: true })
        }
      }
      if (root.sections.length > 0)
        rows.push({ _header: "Actions" })
      for (var i = 0; i < root.sections.length; i++) {
        var id = root.sections[i]
        if (!root.visibleSectionEligible(id)) continue
        rows.push(MenuModel.displayRow(root.menuItems, root.menuOrder, root.checkedResults, root.menuItems[id], "", 0, "menu"))
      }
      return rows
    }
    var out = []
    for (var j = 0; j < root.menuOrder.length; j++) {
      var c = root.menuItems[root.menuOrder[j]]
      if (c && c.parent === root.currentId && MenuModel.isVisible(root.menuItems, root.menuOrder, root.whenResults, c))
        out.push(MenuModel.displayRow(root.menuItems, root.menuOrder, root.checkedResults, c, "", 0, "menu"))
    }
    var prov = root.providerRows[root.currentId]
    if (prov) for (var q = 0; q < prov.length; q++) out.push(prov[q])
    return out
  }

  function rebuildBrowse() {
    var keep = root.browseCursor
    root.browseModel = root.browseRows()
    if (root.browseCursor >= root.browseModel.length) root.browseCursor = 0
    else root.browseCursor = keep
  }

  function pathLabel(id) {
    if (id === "root") return "Actions"
    return MenuModel.pathFor(root.menuItems, id)
  }

  function openSection(id) {
    if (!id || id === "root") {
      root.stack = ["root"]
      root.currentId = "root"
      root.browseCursor = 0
      root.rebuildBrowse()
      root.focusSearch()
      return
    }
    root.stack = root.stack.concat([id])
    root.currentId = id
    root.browseCursor = 0
    var entry = root.menuItems[id]
    if (entry && entry.provider && !root.providerRows[id]) root.runProvider(id)
    root.rebuildBrowse()
    root.focusSearch()
  }

  function goBack() {
    if (root.stack.length <= 1) return
    root.stack = root.stack.slice(0, root.stack.length - 1)
    root.currentId = root.stack[root.stack.length - 1]
    root.browseCursor = 0
    root.rebuildBrowse()
    root.focusSearch()
  }

  function activateBrowseRow(row) {
    if (!row) return
    root.hideCtx()
    if (row._pinned) {
      root.launchAppId(row.appId)
      return
    }
    if (row.kind === "action") {
      if (row.action) root.runCommand(row.action)
      return
    }
    if (row.provider) {
      root.openSection(row.itemId)
      return
    }
    var target = row.target || (row.itemId !== "go" ? row.itemId : "")
    if (target && root.menuItems[target] && (root.menuItems[target].kind === "menu" || root.menuItems[target].provider))
      root.openSection(target)
    else if (row.action)
      root.runCommand(row.action)
  }

  // ---------------------------------------------------------------- providers

  readonly property var providers: ({
    "fonts": {
      icon: "\ue96f",
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done"
    },
    "power-profiles": {
      icon: "\udb81\udc0b",
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done"
    }
  })

  function runProvider(id) {
    var entry = root.menuItems[id]
    if (!entry || !entry.provider) return
    var spec = root.providers[entry.provider]
    if (!spec) return
    providerProc.menuId = id
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function applyProvider(text, id) {
    var key = id || providerProc.menuId
    var entry = root.menuItems[key]
    if (!entry) return
    var spec = root.providers[entry.provider]
    if (!spec) return
    var lines = String(text || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      if (!label) continue
      var slug = MenuModel.slugify(value)
      var action = spec.actionFor ? spec.actionFor(value) : "omarchy-font-set " + Util.shellQuote(value)
      rows.push({ itemId: key + "." + slug, kind: "action", icon: spec.icon, label: label, action: action, provider: "", childCount: 0, target: "" })
    }
    root.providerRows[key] = rows
    if (root.currentId === key) root.rebuildBrowse()
  }

  // ---------------------------------------------------------------- guards

  function evaluateGuards() {
    var script = MenuModel.guardScript(root.menuItems)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      root.rebuildBrowse()
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  function applyGuards(text) {
    var w = ({})
    var c = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^([^:]+):([wc]):([01])$/.exec(lines[i].trim())
      if (m) {
        if (m[2] === "w") w[m[1]] = m[3] === "1"
        else c[m[1]] = m[3] === "1"
      }
    }
    root.whenResults = w
    root.checkedResults = c
    root.rebuildBrowse()
  }

  // ---------------------------------------------------------------- places

  function buildPlaces(text) {
    var map = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split("\t")
      if (parts.length >= 3 && parts[0] === "PLACE") map[parts[1]] = parts[2]
    }
    var home = map.HOME || ""
    var labels = [
      [ "HOME", "Home" ], [ "DOCUMENTS", "Documents" ], [ "DOWNLOAD", "Downloads" ],
      [ "PICTURES", "Pictures" ], [ "MUSIC", "Music" ], [ "VIDEOS", "Videos" ]
    ]
    var out = []
    for (var k = 0; k < labels.length; k++) {
      var path = map[labels[k][0]] || (home ? home + "/" + labels[k][1] : "")
      if (path) out.push({ label: labels[k][1], path: path })
    }
    root.places = out
  }

  // ---------------------------------------------------------------- context menu

  property string ctxId: ""
  property point ctxPos: Qt.point(0, 0)

  function showCtxAt(fromItem, anchorX, anchorY, id) {
    if (!fromItem || !fromItem.mapToItem || !ctxMenu) { root.hideCtx(); return }
    var p = fromItem.mapToItem(ctxMenu.parent, anchorX, anchorY)
    root.ctxPos = Qt.point(Math.round(p.x + Style.spacing.xs), Math.round(p.y + Style.spacing.xs))
    root.ctxId = String(id)
    ctxMenu.visible = true
  }

  function hideCtx() {
    ctxMenu.visible = false
  }

  function ctxLabel() {
    return root.isPinned(root.ctxId) ? "Unpin from start menu" : "Pin to start menu"
  }

  function ctxAct() {
    var id = root.ctxId
    if (!id) return
    if (root.isPinned(id)) root.unpin(id)
    else root.pin(id)
    root.hideCtx()
  }

  // ---------------------------------------------------------------- commands

  function runCommand(cmd) {
    if (!cmd) return
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run(cmd)
    else
      Quickshell.execDetached(cmd)
    root.close()
  }

  function openPlace(path) {
    if (!path) return
    root.hideCtx()
    root.runCommand("xdg-open " + Util.shellQuote(path))
  }

  function refresh() {
    if (root.appLibrary && typeof root.appLibrary.refreshIcons === "function")
      root.appLibrary.refreshIcons()
  }

  function open() {
    if (typeof searchField !== "undefined" && searchField) searchField.text = ""
    root.searchText = ""
    root.gridIndex = 0
    root.stack = ["root"]
    root.currentId = "root"
    root.browseCursor = 0
    root.hideCtx()
    root.rebuildBrowse()
    root.refresh()
    root.controller.show()
  }

  onOpenedChanged: {
    if (!root.opened) root.hideCtx()
  }

  // ---------------------------------------------------------------- load

  FileView {
    id: menuDefaultFile
    path: root.menuDefaultPath
    watchChanges: true
    printErrors: false
    onLoaded: root.rebuildMenu()
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.menuUserPath
    watchChanges: true
    printErrors: false
    onLoaded: root.rebuildMenu()
    onLoadFailed: root.rebuildMenu()
    onFileChanged: reload()
  }

  Process {
    id: placesProc
    property string collected: ""
    command: ["bash", "-lc",
      "for k in DOCUMENTS DOWNLOAD PICTURES MUSIC VIDEOS DESKTOP; do v=$(xdg-user-dir \"$k\" 2>/dev/null); if [[ -z $v || $v = \"$HOME\" ]]; then case $k in DOCUMENTS) v=\"$HOME/Documents\";; DOWNLOAD) v=\"$HOME/Downloads\";; PICTURES) v=\"$HOME/Pictures\";; MUSIC) v=\"$HOME/Music\";; VIDEOS) v=\"$HOME/Videos\";; DESKTOP) v=\"$HOME/Desktop\";; esac; fi; printf 'PLACE\\t%s\\t%s\\n' \"$k\" \"$v\"; done; printf 'PLACE\\tHOME\\t%s\\n' \"$HOME\""]
    stdout: SplitParser {
      onRead: function(data) { placesProc.collected += data + "\n" }
    }
    onExited: root.buildPlaces(placesProc.collected)
  }

  Process {
    id: pinnedProc
    property string collected: ""
    command: ["bash", "-c", "test -f \"$HOME/.local/state/omarchy/startmenu/pinned\" && cat \"$HOME/.local/state/omarchy/startmenu/pinned\" || true"]
    stdout: SplitParser {
      onRead: function(data) { pinnedProc.collected += data + "\n" }
    }
    onExited: root.applyPinned(pinnedProc.collected)
  }

  FileView {
    id: opacityFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyOpacity(text())
    onLoadFailed: root.cardOpacity = 1
    onFileChanged: reload()
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: root.applyGuards(guardProc.collected)
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: root.applyProvider(providerProc.collected, providerProc.menuId)
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      root.rebuildMenu()
      root.rebuildPinned()
    }
  }

  Component.onCompleted: {
    placesProc.running = true
    pinnedProc.running = true
    Qt.callLater(function() { root.rebuildMenu() })
  }

  // ---------------------------------------------------------------- popup

  StartPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    cardColor: root.cardFill
    contentWidth: panel.fittedContentWidth(Math.round(Style.space(640)))
    contentHeight: panel.fittedContentHeight(Math.round(Style.space(548)))

    ColumnLayout {
      id: rootContent
      anchors.fill: parent
      spacing: Style.spacing.md

      // Search field: owns its text natively (Backspace, space, cursor all
      // work); the Keys handler only intercepts navigation/activation.
      TextField {
        id: searchField
        Layout.fillWidth: true
        Layout.preferredHeight: root.searchHeight
        placeholderText: "Search applications…"
        color: root.fg
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        selectByMouse: true
        placeholderTextColor: root.muted

        background: Rectangle {
          radius: root.cornerRadius * 0.5
          color: Color.menu.selectedBackground
          border.width: 1
          border.color: root.border
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            hideCtx()
            if (root.searching()) { searchField.clear(); event.accepted = true; return }
            if (root.stack.length > 1) { root.goBack(); event.accepted = true; return }
            panel.close(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateTarget(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Up) { root.moveCursor(0, -1); event.accepted = true; return }
          if (event.key === Qt.Key_Down) { root.moveCursor(0, 1); event.accepted = true; return }
          if (event.key === Qt.Key_Left && !root.searching() && root.browseCursor > 0) {
            root.moveCursor(-1, 0); event.accepted = true; return
          }
          if (event.key === Qt.Key_Right && !root.searching()) {
            root.moveCursor(1, 0); event.accepted = true; return
          }
        }

        onTextChanged: {
          root.searchText = text
          root.gridIndex = 0
        }
        onAccepted: root.activateTarget()
      }

      // Body: places rail + main pane
      RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.spacing.lg

        // ---- left rail: Places
        Column {
          Layout.preferredWidth: Math.round(Style.space(168))
          Layout.fillHeight: true
          spacing: Style.spacing.xs

          Text {
            text: "Places"
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            leftPadding: Style.spacing.xs
          }

          Repeater {
            model: root.places
            delegate: placeDelegate
          }
        }

        // ---- main pane
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.sm

          // breadcrumb — only when drilling into a section
          RowLayout {
            Layout.fillWidth: true
            visible: !root.searching() && root.stack.length > 1

            MouseArea {
              Layout.preferredHeight: Math.round(Style.spacing.controlHeight * 0.6)
              Layout.fillWidth: true
              enabled: root.stack.length > 1
              cursorShape: Qt.PointingHandCursor
              hoverEnabled: true
              onClicked: root.goBack()

              RowLayout {
                anchors.fill: parent
                spacing: Style.spacing.sm

                Text {
                  text: "\uf060"
                  color: root.accent
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: root.pathLabel(root.currentId)
                  color: root.muted
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
            }

            Text {
              text: "Back"
              color: root.accent
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goBack()
              }
            }
          }

          // section list (scrollable) — visible when not searching
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.searching()

            ListView {
              id: browseList
              anchors.fill: parent
              model: root.browseModel
              clip: true
              spacing: Style.spacing.xs
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: browseDelegate
            }
          }

          // search results grid — visible while searching
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.searching()

            GridView {
              id: appGrid
              anchors.fill: parent
              model: root.visibleApps()
              cellWidth: Math.max(Math.round(Style.space(92)), Math.round((width - Style.spacing.md * (root.gridColumns() - 1)) / root.gridColumns()))
              cellHeight: Math.round(Style.space(92))
              clip: true
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: appDelegate
            }
          }
        }
      }

      // Footer: transparency + session
      RowLayout {
        Layout.fillWidth: true
        Layout.preferredHeight: root.footerHeight
        spacing: Style.spacing.sm

        Text {
          text: "Transparency"
          color: root.muted
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }

        PanelSlider {
          id: opacitySlider
          bar: root.bar
          Layout.fillWidth: true
          Layout.preferredWidth: Math.round(Style.space(160))
          minimum: 0
          maximum: 1
          step: 0.01
          value: root.cardOpacity
          onMoved: function(v) { root.cardOpacity = v }
          onReleased: function(v) { root.cardOpacity = v; root.saveOpacity() }
        }

        Item { Layout.fillWidth: true }

        Repeater {
          model: root.powerActions
          delegate: powerButtonDelegate
        }
      }
    }

    // Context menu for pinning (sibling of the layout, sits in the same
    // surface so it overlays the content; not layout-managed).
    Rectangle {
      id: ctxMenu
      visible: false
      width: Math.round(Style.space(190))
      height: Math.round(Style.space(36))
      x: root.ctxPos.x
      y: root.ctxPos.y
      z: 100
      radius: root.cornerRadius * 0.5
      color: Color.menu.selectedBackground
      border.width: 1
      border.color: root.border

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.ctxLabel()
        color: root.cellText
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.ctxAct()
      }
    }
  }

  // ---------------------------------------------------------------- delegates

  Component {
    id: placeDelegate
    Rectangle {
      required property var modelData
      required property int index
      width: parent ? parent.width : 0
      height: Math.round(Style.space(30))
      radius: root.cornerRadius * 0.5
      color: hover.containsMouse ? root.cellHover : "transparent"
      border.width: hover.containsMouse ? 1 : 0
      border.color: root.border

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.focusSearch()
          root.openPlace(modelData.path)
        }
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf07b"
          color: root.fg
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(Style.space(14))
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: root.cellText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width - Style.spacing.md * 2
        }
      }
    }
  }

  Component {
    id: browseDelegate
    Rectangle {
      required property var modelData
      required property int index
      width: parent ? parent.width : 0
      height: modelData._header ? Math.round(Style.spacing.controlHeight * 0.6) : Math.round(Style.space(36))
      radius: modelData._header ? 0 : root.cornerRadius * 0.5
      color: modelData._header ? "transparent" : (root.browseCursor === index || hover.containsMouse ? root.cellHover : "transparent")
      border.width: modelData._header ? 0 : ((root.browseCursor === index || hover.containsMouse) ? 1 : 0)
      border.color: root.browseCursor === index ? root.accent : root.border

      Text {
        visible: !!modelData._header
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        text: modelData._header || ""
        color: root.muted
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        enabled: !modelData._header
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button !== Qt.LeftButton) return
          root.browseCursor = index
          root.activateBrowseRow(modelData)
          root.focusSearch()
        }
        onPressed: function(mouse) {
          if (mouse.button === Qt.RightButton) {
            if (modelData._pinned || modelData.kind === "app")
              root.showCtxAt(hover, mouse.x, mouse.y, modelData.appId)
          }
        }
      }

      RowLayout {
        anchors.fill: parent
        visible: !modelData._header
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.sm
        spacing: Style.spacing.sm

        Item {
          width: Math.round(Style.space(24))
          height: parent.height

          Image {
            anchors.centerIn: parent
            width: Math.round(Style.space(22))
            height: Math.round(Style.space(22))
            visible: root.rowAppIcon(modelData) !== ""
            source: root.rowAppIcon(modelData)
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            smooth: true
            asynchronous: true
            fillMode: Image.PreserveAspectFit
          }

          Text {
            anchors.centerIn: parent
            visible: root.rowAppIcon(modelData) === ""
            text: modelData.icon || ""
            color: root.fg
            font.family: modelData.iconFont || Style.font.menuFamily
            font.pixelSize: Math.round(Style.space(17))
          }
        }

        Text {
          text: modelData.label || ""
          color: root.cellText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        Text {
          visible: modelData._pinned || modelData.childCount > 0 || modelData.provider !== ""
          text: modelData._pinned ? "\uf022" : "\uf105"
          color: root.muted
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component {
    id: appDelegate
    Rectangle {
      required property var modelData
      required property int index
      width: appGrid.cellWidth
      height: appGrid.cellHeight
      radius: root.cornerRadius * 0.6
      color: root.gridIndex === index || hover.containsMouse ? root.cellHover : "transparent"
      border.width: (root.gridIndex === index || hover.containsMouse) ? 1 : 0
      border.color: root.gridIndex === index ? root.accent : root.border

      MouseArea {
        id: hover
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button !== Qt.LeftButton) return
          root.focusSearch()
          root.gridIndex = index
          root.launchDesktop(modelData)
        }
        onPressed: function(mouse) {
          if (mouse.button === Qt.RightButton)
            root.showCtxAt(hover, mouse.x, mouse.y, root.appId(modelData))
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.xs
        spacing: Style.spacing.xs

        Item {
          width: parent.width
          height: parent.height * 0.46

          Image {
            anchors.centerIn: parent
            width: Math.round(Style.space(26))
            height: Math.round(Style.space(26))
            source: root.iconSource(modelData)
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            smooth: true
            asynchronous: true
            fillMode: Image.PreserveAspectFit
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - Style.spacing.sm
          text: root.entryName(modelData)
          color: root.cellText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  Component {
    id: powerButtonDelegate
    Rectangle {
      required property var modelData
      Layout.preferredWidth: Math.round(Style.space(72))
      Layout.preferredHeight: root.footerHeight
      radius: root.cornerRadius * 0.5
      color: hover.containsMouse ? root.cellHover : "transparent"
      border.width: hover.containsMouse ? 1 : 0
      border.color: root.border

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.focusSearch()
          root.runCommand(modelData.cmd)
        }
      }

      Row {
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.icon
          color: root.fg
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: root.cellText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}