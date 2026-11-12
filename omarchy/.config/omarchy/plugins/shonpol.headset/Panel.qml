import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Headset widget: battery of a wireless headset on the bar (headsetcontrol),
// and a panel to set sidetone and switch EasyEffects presets. headset.sh does
// the talking; this file only ever runs it with an argv list.
//
// Left click opens the panel, right click opens EasyEffects, middle click
// switches to the next output preset.
// Panel keys: j/k or arrows move, h/l adjust sidetone or pick a preset,
// Enter applies (on sidetone it toggles it off/on), r refreshes, Esc closes.
//
// IPC: omarchy-shell shonpol.headset toggle | nextPreset | refresh
//
// Settings (this widget's entry in ~/.config/omarchy/shell.json):
//   interval         polling period in ms while the panel is closed (default 30000)
//   lowBattery       notify once when the battery reaches this % (default 15, 0 = never)
//   sidetone         sidetone level used before one has been set here (default 64)
//   reapplySidetone  set the remembered sidetone again when the headset turns on (default true)
//   name             title in the panel (default: product name from headsetcontrol)
//   hideWhenOffline  hide the bar icon while the headset is off (default false)
//   language         catalog code to force for this panel, e.g. "es" (default: Omarchy's language)
Panel {
  id: root
  moduleName: "shonpol.headset"
  ipcTarget: "shonpol.headset"
  // The IPC handler below adds nextPreset/refresh to the usual verbs.
  manageIpc: false

  readonly property int interval: Math.max(5000, Math.min(300000, Number(setting("interval", 30000)) || 30000))
  readonly property int openInterval: 4000
  readonly property int lowBattery: Math.max(0, Math.min(50, Math.round(Number(setting("lowBattery", 15)))))
  readonly property int defaultSidetone: Model.clampSidetone(setting("sidetone", 64))
  readonly property bool reapplySidetone: setting("reapplySidetone", true) !== false
  readonly property bool hideWhenOffline: setting("hideWhenOffline", false) === true
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("headset.sh")).replace(/^file:\/\//, ""))

  // `state` is taken by Item, hence `hs`.
  property var hs: Model.emptyState()
  property bool loaded: false
  property bool lowNotified: false
  property bool pendingRefresh: false
  property var actionQueue: []

  // Sidetone shown/applied: the level being set right now, else the one
  // remembered by headset.sh, else the `sidetone` setting.
  property int sidetoneOverride: -1
  readonly property int sidetone: sidetoneOverride >= 0 ? sidetoneOverride : (hs.sidetone >= 0 ? hs.sidetone : defaultSidetone)
  property int restoreSidetone: defaultSidetone
  onSidetoneChanged: if (sidetone > 0) restoreSidetone = sidetone

  readonly property bool online: Model.online(hs)
  readonly property bool low: lowBattery > 0 && Model.isLow(hs, lowBattery)
  readonly property string displayName: String(setting("name", Model.shortProduct(hs.product) || root.tr("title"))).substring(0, 40)

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------- language override ----------
  // `language` in this widget's settings (e.g. "es") shows the panel in that
  // language whatever Omarchy is set to; missing strings fall through to the
  // Translations layers, which follow Setup > Language.
  readonly property string languageOverride: String(setting("language", "")).replace(/[^A-Za-z-]/g, "").substring(0, 12)
  readonly property string overrideBase: languageOverride.split("-")[0]
  readonly property string i18nDir: decodeURIComponent(String(Qt.resolvedUrl("i18n")).replace(/^file:\/\//, ""))
  readonly property var overrideLayers: [
    strings.parseCatalog(overrideFile.text()),
    strings.parseCatalog(overrideBaseFile.text())
  ]

  FileView {
    id: overrideFile
    path: root.languageOverride !== "" ? root.i18nDir + "/" + root.languageOverride + ".json" : ""
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }

  FileView {
    id: overrideBaseFile
    path: root.overrideBase !== root.languageOverride && root.overrideBase !== "" ? root.i18nDir + "/" + root.overrideBase + ".json" : ""
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }

  function tr(key) {
    for (var i = 0; i < overrideLayers.length; i++) {
      var value = overrideLayers[i][key]
      if (typeof value === "string" && value.length > 0) return value
    }
    return strings.t(key)
  }

  function num(value) { return Commons.I18n.formatNumber(value, 0) }

  // ---------- derived text ----------

  readonly property string barText: Model.barText(hs, button.vertical, root.num)

  readonly property string statusText: {
    if (!loaded) return root.tr("status.waiting")
    switch (hs.battery) {
    case "absent": return root.tr("status.absent")
    case "offline": return root.tr("status.offline")
    case "charging": return hs.level >= 0 ? root.tr("status.chargingLevel").arg(root.num(hs.level)) : root.tr("status.charging")
    default: return root.low ? root.tr("status.low") : root.tr("status.connected")
    }
  }

  // ---------- polling ----------

  function refresh() {
    if (statusProc.running) { pendingRefresh = true; return }
    statusProc.running = true
  }

  function applyStatus(raw) {
    var next = Model.parseStatus(raw)
    if (reapplySidetone && next.sidetoneCap && Model.cameOnline(loaded ? hs : null, next))
      runAction(["sidetone", String(sidetoneOverride >= 0 ? sidetoneOverride : (next.sidetone >= 0 ? next.sidetone : defaultSidetone))])

    var step = Model.lowBatteryStep(lowNotified, next, Math.max(1, lowBattery))
    lowNotified = step.notified
    if (step.notify && lowBattery > 0) notifyLow(next.level)

    // Keep the level being dragged until headset.sh has stored it.
    if (sidetoneOverride >= 0 && next.sidetone === sidetoneOverride && !sidetoneTimer.running && actionQueue.length === 0 && !actionProc.running)
      sidetoneOverride = -1
    hs = next
    loaded = true
    clampCursor()
  }

  Process {
    id: statusProc
    command: ["bash", root.scriptPath, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: if (root.pendingRefresh) { root.pendingRefresh = false; Qt.callLater(root.refresh) }
  }

  Timer {
    interval: root.opened ? root.openInterval : root.interval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer { id: refreshSoon; interval: 300; onTriggered: root.refresh() }
  Timer { id: refreshAfterStart; interval: 2500; onTriggered: root.refresh() }

  onOpenedChanged: {
    if (opened) refresh()
    else cursorActive = false
  }

  // ---------- actions ----------
  // One headset.sh action at a time. Queued sidetone/effects requests replace
  // an older one of the same kind, so dragging the slider never piles up.

  function runAction(args) {
    var queue = actionQueue.filter(function(a) { return args[0] === "preset" || a[0] !== args[0] })
    queue.push(args)
    actionQueue = queue
    pumpActions()
  }

  function pumpActions() {
    if (actionProc.running || actionQueue.length === 0) return
    var next = actionQueue[0]
    actionQueue = actionQueue.slice(1)
    actionProc.command = ["bash", root.scriptPath].concat(next)
    actionProc.running = true
  }

  Process {
    id: actionProc
    onExited: {
      if (root.actionQueue.length > 0) Qt.callLater(root.pumpActions)
      else refreshSoon.restart()
    }
  }

  Timer {
    id: sidetoneTimer
    interval: 120
    onTriggered: root.runAction(["sidetone", String(root.sidetone)])
  }

  function setSidetone(value) {
    sidetoneOverride = Model.clampSidetone(value)
    sidetoneTimer.restart()
  }

  function toggleSidetone() {
    setSidetone(sidetone > 0 ? 0 : (restoreSidetone > 0 ? restoreSidetone : defaultSidetone))
  }

  function loadPreset(name, kind) {
    if (!hs.ee || name === "") return
    var list = kind === "input" ? hs.inputPresets : hs.outputPresets
    if (list.indexOf(name) === -1) return
    var patch = kind === "input" ? { input: name } : { output: name }
    hs = Object.assign({}, hs, patch)
    runAction(["preset", name])
  }

  function nextPreset() {
    var name = Model.cyclePreset(hs.outputPresets, hs.output, 1)
    if (name === "") return
    loadPreset(name, "output")
    Quickshell.execDetached(["notify-send", "-a", root.tr("title"), "-i", "audio-headset", "-t", "2000", "-e",
                             root.tr("notify.preset").arg(name)])
  }

  function setEffects(on) {
    if (!hs.ee) return
    hs = Object.assign({}, hs, { bypass: !on })
    runAction(["effects", on ? "on" : "off"])
  }

  function openEasyEffects() {
    Quickshell.execDetached(["easyeffects"])
    root.close()
  }

  function startEasyEffects() {
    Quickshell.execDetached(["easyeffects", "--hide-window"])
    refreshAfterStart.restart()
  }

  function notifyLow(level) {
    Quickshell.execDetached(["notify-send", "-a", root.tr("title"), "-i", "battery-low", "-u", "normal",
                             root.tr("notify.lowTitle"), root.tr("notify.lowBody").arg(root.num(level))])
  }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function nextPreset(): void { root.nextPreset() }
    function refresh(): void { root.refresh() }
  }

  // ---------- keyboard / mouse cursor ----------
  // One cursor shared by keys and hover, over the rows that exist right now.

  property bool cursorActive: false
  property string cursorRow: ""
  property int chipIndex: 0

  readonly property var rows: {
    var r = []
    if (hs.present && hs.sidetoneCap) r.push("sidetone")
    if (hs.ee && hs.outputPresets.length > 0) r.push("output")
    if (hs.ee && hs.inputPresets.length > 0) r.push("input")
    if (hs.ee) r.push("effects")
    r.push("easyeffects")
    return r
  }

  function hasCursor(row) { return cursorActive && cursorRow === row }

  function presetsFor(row) { return row === "input" ? hs.inputPresets : (row === "output" ? hs.outputPresets : []) }

  function setCursor(row, chip) {
    cursorActive = true
    cursorRow = row
    if (chip !== undefined) chipIndex = chip
    else {
      var list = presetsFor(row)
      var current = list.indexOf(row === "input" ? hs.input : hs.output)
      chipIndex = current >= 0 ? current : 0
    }
  }

  function clampCursor() {
    if (!cursorActive) return
    if (rows.indexOf(cursorRow) === -1) setCursor(rows[0])
    var list = presetsFor(cursorRow)
    if (list.length > 0) chipIndex = Math.max(0, Math.min(list.length - 1, chipIndex))
  }

  function moveCursor(dx, dy) {
    if (!cursorActive || rows.indexOf(cursorRow) === -1) { setCursor(rows[0]); return }
    if (dy !== 0) {
      var i = Math.max(0, Math.min(rows.length - 1, rows.indexOf(cursorRow) + dy))
      setCursor(rows[i])
      return
    }
    if (dx === 0) return
    if (cursorRow === "sidetone") {
      if (root.online) setSidetone(sidetone + dx * 8)
    } else if (cursorRow === "output" || cursorRow === "input") {
      chipIndex = Math.max(0, Math.min(presetsFor(cursorRow).length - 1, chipIndex + dx))
    } else if (cursorRow === "effects") {
      setEffects(dx > 0)
    }
  }

  function activateCursor() {
    if (!cursorActive) { setCursor(rows[0]); return }
    switch (cursorRow) {
    case "sidetone": if (root.online) toggleSidetone(); break
    case "output":
    case "input":
      var list = presetsFor(cursorRow)
      if (chipIndex >= 0 && chipIndex < list.length) loadPreset(list[chipIndex], cursorRow)
      break
    case "effects": setEffects(hs.bypass); break
    case "easyeffects": hs.ee ? openEasyEffects() : startEasyEffects(); break
    }
  }

  // ---------- bar button ----------

  visible: !(hideWhenOffline && loaded && !online)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.low
    dimmed: root.loaded && !root.online
    horizontalMargin: Number(root.setting("horizontalMargin", 7.5))
    verticalPadding: Number(root.setting("verticalPadding", 6))
    fontSize: Number(root.setting("fontSize", 12))
    // The panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.openEasyEffects()
      else if (b === Qt.MiddleButton) root.nextPreset()
      else root.toggle()
    }
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refresh() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · name/status · battery ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroBattery.implicitHeight)

            PlainText {
              id: heroIcon
              text: root.online ? "󰋋" : "󰟎"
              color: root.low ? root.hotColor : root.fg
              opacity: root.online || !root.loaded ? 1 : 0.5
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Behavior on color { ColorAnimation { duration: Style.duration(200) } }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroBattery.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PlainText {
                text: root.displayName
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              PlainText {
                text: root.statusText.toUpperCase()
                color: root.low ? root.hotColor : root.dim
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Column {
              id: heroBattery
              visible: root.online
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              PlainText {
                anchors.right: parent.right
                text: root.hs.level >= 0 ? root.num(root.hs.level) + "%" : "󱐋"
                color: root.low ? root.hotColor : root.fg
                font.pixelSize: Style.font.display
                font.bold: true
              }

              PlainText {
                anchors.right: parent.right
                text: root.tr("battery").toUpperCase()
                opacity: 0.6
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }
          }

          Item {
            visible: root.online && root.hs.level >= 0
            width: parent.width
            implicitHeight: Style.space(6)

            Rectangle {
              id: batteryTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            }

            Rectangle {
              anchors.left: batteryTrack.left
              anchors.verticalCenter: batteryTrack.verticalCenter
              height: batteryTrack.height
              radius: batteryTrack.radius
              color: root.low ? root.hotColor : root.fg
              width: Math.max(batteryTrack.height, batteryTrack.width * Model.batteryFraction(root.hs))
              Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: Style.duration(200) } }
            }
          }
        }

        // ---------- Sidetone ----------
        Column {
          visible: root.hs.present && root.hs.sidetoneCap
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(sidetoneHeader.implicitHeight, sidetoneValue.implicitHeight)

            PanelSectionHeader {
              id: sidetoneHeader
              text: root.tr("section.sidetone")
              foreground: root.fg
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PlainText {
              id: sidetoneValue
              readonly property int shown: sidetoneSlider.dragging ? Math.round(sidetoneSlider.liveValue) : root.sidetone
              text: shown === 0 ? root.tr("sidetone.off") : root.num(shown)
              color: root.dim
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            width: parent.width
            height: sidetoneSlider.implicitHeight + Style.spacing.controlGap
            hasCursor: root.hasCursor("sidetone")
            foreground: root.fg
            outline: true

            PanelSlider {
              id: sidetoneSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: 0
              maximum: 128
              step: 8
              integer: true
              value: root.sidetone
              enabled: root.online
              opacity: root.online ? 1 : 0.4
              onMoved: function(v) { root.setSidetone(v) }
              onRightClicked: root.toggleSidetone()
            }

            HoverHandler { onHoveredChanged: if (hovered) root.setCursor("sidetone") }
          }

          PlainText {
            visible: !root.online
            width: parent.width
            text: root.tr("sidetone.offline")
            color: root.dim
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- EasyEffects ----------
        PanelSeparator { foreground: root.fg }

        PresetRow {
          visible: root.hs.ee && root.hs.outputPresets.length > 0
          row: "output"
          title: root.tr("section.output")
          presets: root.hs.outputPresets
          current: root.hs.output
        }

        PresetRow {
          visible: root.hs.ee && root.hs.inputPresets.length > 0
          row: "input"
          title: root.tr("section.input")
          presets: root.hs.inputPresets
          current: root.hs.input
        }

        Toggle {
          visible: root.hs.ee
          width: parent.width
          label: root.tr("effects.title")
          description: root.hs.bypass ? root.tr("effects.bypassed") : root.tr("effects.active")
          checked: !root.hs.bypass
          hasCursor: root.hasCursor("effects")
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.setEffects(root.hs.bypass)
          onHovered: function(h) { if (h) root.setCursor("effects") }
        }

        PlainText {
          visible: root.loaded && !root.hs.ee
          width: parent.width
          text: root.tr("ee.notRunning")
          color: root.dim
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          width: parent.width
          iconText: "󰓃"
          iconSize: Style.font.title
          text: root.hs.ee ? root.tr("ee.open") : root.tr("ee.start")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          hasCursor: root.hasCursor("easyeffects")
          onHovered: function(h) { if (h) root.setCursor("easyeffects") }
          onClicked: root.hs.ee ? root.openEasyEffects() : root.startEasyEffects()
        }
      }
    }
  }

  // ---------- components ----------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
  }

  component PresetRow: Column {
    id: presetRow
    property string row: ""
    property string title: ""
    property var presets: []
    property string current: ""

    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: presetRow.title
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    ButtonGroup {
      width: parent.width
      options: presetRow.presets
      value: presetRow.current
      focusable: false
      cursorIndex: root.hasCursor(presetRow.row) ? root.chipIndex : -1
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.loadPreset(v, presetRow.row) }
      onHovered: function(index, h) { if (h) root.setCursor(presetRow.row, index) }
    }
  }
}
