import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Hardware monitor: CPU and GPU temperatures on the bar, and a panel with
// load, clocks, power, memory and the Kraken AIO. sensors.sh reads /sys and
// /proc on every tick; the panel keeps a few minutes of temperature history
// so opening it shows the trend, not just the current reading.
//
// Left click opens the panel, right click opens btop in a floating terminal.
// IPC: omarchy-shell shonpol.hwmon toggle
//
// Settings (this widget's entry in ~/.config/omarchy/shell.json):
//   interval  polling period in ms (default 3000, 1000..60000)
//   cpuName   label for the CPU section (default: detected from /proc/cpuinfo)
//   gpuName   label for the GPU section (default "GPU")
//   language  catalog code to force for this panel, e.g. "es" (default: Omarchy's language)
Panel {
  id: root
  moduleName: "shonpol.hwmon"
  ipcTarget: "shonpol.hwmon"

  readonly property int historyLength: 60
  readonly property int interval: Math.max(1000, Math.min(60000, Number(setting("interval", 3000)) || 3000))
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("sensors.sh")).replace(/^file:\/\//, ""))

  property var readings: ({})
  property var previousSample: null
  property int cpuLoad: -1
  property string detectedCpuName: ""
  property var cpuHistory: []
  property var gpuHistory: []

  readonly property bool hasData: readings.cpu_temp !== undefined || readings.gpu_edge !== undefined
  readonly property int overall: Model.overallSeverity(readings)
  readonly property bool alert: Model.barAlert(readings)
  readonly property string cpuName: String(setting("cpuName", detectedCpuName || "CPU")).substring(0, 32)
  readonly property string gpuName: String(setting("gpuName", "GPU")).substring(0, 32)
  readonly property int historyMinutes: Math.max(1, Math.round(historyLength * interval / 60000))

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property color gpuLineColor: Commons.Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property real openPanelIndicatorWidth: button.vertical ? 0 : button.labelWidth

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------- language override ----------
  // `language` in this widget's settings (e.g. "es") shows the panel in that
  // language whatever Omarchy is set to. Its catalog (then its base language
  // for a regional code) is read first; anything missing falls through to the
  // Translations layers above, which follow Setup > Language as usual.
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

  function overrideEntry(key) {
    for (var i = 0; i < overrideLayers.length; i++) {
      var value = overrideLayers[i][key]
      if (typeof value === "string" || (value && typeof value === "object")) return value
    }
    return undefined
  }

  function tr(key) {
    var value = overrideEntry(key)
    if (value && typeof value === "object") value = value.other
    return typeof value === "string" && value.length > 0 ? value : strings.t(key)
  }

  // The override catalogs shipped here (en, es) only need "one" and "other".
  function trn(key, count) {
    var value = overrideEntry(key)
    if (typeof value === "string" && value.length > 0) return value
    if (value && typeof value === "object") {
      var form = count === 1 && typeof value.one === "string" ? value.one : value.other
      if (typeof form === "string" && form.length > 0) return form
    }
    return strings.tn(key, count)
  }

  // ---------- formatting ----------

  function num(value, decimals) { return Commons.I18n.formatNumber(value, decimals) }

  function deg(milli, decimals) {
    var c = Model.celsius(milli)
    return isFinite(c) ? num(c, decimals || 0) + " °C" : "—"
  }

  function shortDeg(milli) {
    var c = Model.celsius(milli)
    return isFinite(c) ? num(c, 0) + "°" : "—"
  }

  function plain(value, unit, decimals) {
    return value === undefined || value === null || value < 0 ? "—" : num(value, decimals || 0) + " " + unit
  }

  function gib(usedMib, totalMib) {
    if (usedMib === undefined || totalMib === undefined) return "—"
    return num(usedMib / 1024, 1) + " / " + num(totalMib / 1024, 0) + " GiB"
  }

  function fanText(rpm) {
    if (rpm === undefined) return "—"
    return rpm === 0 ? root.tr("gpu.fanStopped") : num(rpm, 0) + " RPM"
  }

  function toneFor(key) {
    return Model.severity(key, readings[key])
  }

  readonly property string barText: {
    if (!hasData) return button.vertical ? "󰻠" : "󰻠 —"
    if (button.vertical) return shortDeg(readings.cpu_temp) + "\n" + shortDeg(readings.gpu_edge)
    return "󰻠 " + shortDeg(readings.cpu_temp) + "  󰢮 " + shortDeg(readings.gpu_edge)
  }

  readonly property string statusText: {
    if (!hasData) return root.tr("status.waiting")
    if (overall === 2) return root.tr("status.hot")
    if (overall === 1) return root.tr("status.warm")
    return root.tr("status.cool")
  }

  // ---------- sampling ----------

  function refresh() {
    if (!sensorsProc.running) sensorsProc.running = true
  }

  function update(raw) {
    var next = Model.parseReadings(raw)
    if (Object.keys(next).length === 0) return
    cpuLoad = Model.cpuLoad(previousSample, next)
    previousSample = next
    readings = next
    cpuHistory = Model.pushHistory(cpuHistory, Model.celsius(next.cpu_temp), historyLength)
    gpuHistory = Model.pushHistory(gpuHistory, Model.celsius(next.gpu_junction), historyLength)
  }

  function openBtop() {
    Quickshell.execDetached(["xdg-terminal-exec", "--app-id=TUI.float", "-e", "btop"])
    root.close()
  }

  Process {
    id: sensorsProc
    command: ["bash", root.scriptPath]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.update(text) }
  }

  Process {
    id: infoProc
    command: ["bash", root.scriptPath, "--info"]
    running: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.detectedCpuName = Model.shortCpuName(text) }
  }

  Timer {
    interval: root.interval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.alert
    horizontalMargin: Number(root.setting("horizontalMargin", 7.5))
    verticalPadding: Number(root.setting("verticalPadding", 6))
    fontSize: Number(root.setting("fontSize", 12))
    // The panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.openBtop()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onActivateRequested: root.openBtop()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: chip · title/status · CPU and GPU temps ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroTemps.implicitHeight)

          PlainText {
            id: heroIcon
            text: "󰍛"
            color: root.overall === 2 ? root.hotColor : root.fg
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroTemps.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: root.tr("title")
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            PlainText {
              text: root.statusText.toUpperCase()
              color: root.overall === 2 ? root.hotColor : Qt.darker(root.fg, 1.4)
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroTemps
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)

            HeroTemp { caption: "CPU"; milli: root.readings.cpu_temp; tone: root.toneFor("cpu_temp") }
            HeroTemp { caption: "GPU"; milli: root.readings.gpu_edge; tone: Math.max(root.toneFor("gpu_edge"), root.toneFor("gpu_junction")) }
          }
        }

        // ---------- History chart ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Canvas {
            id: chart
            width: parent.width
            height: Style.space(64)

            property var cpu: root.cpuHistory
            property var gpu: root.gpuHistory
            property color lineA: root.fg
            property color lineB: root.gpuLineColor
            onCpuChanged: requestPaint()
            onGpuChanged: requestPaint()
            onLineAChanged: requestPaint()
            onLineBChanged: requestPaint()
            onWidthChanged: requestPaint()

            readonly property real lo: 20
            readonly property real hi: 100

            function yFor(c) {
              var t = (Math.max(lo, Math.min(hi, c)) - lo) / (hi - lo)
              return height - 1 - t * (height - 2)
            }

            function stroke(ctx, values, color) {
              var step = width / (root.historyLength - 1)
              var started = false
              ctx.beginPath()
              for (var i = 0; i < values.length; i++) {
                var v = values[i]
                if (!isFinite(v)) { started = false; continue }
                var x = width - (values.length - 1 - i) * step
                if (!started) { ctx.moveTo(x, yFor(v)); started = true }
                else ctx.lineTo(x, yFor(v))
              }
              ctx.strokeStyle = color
              ctx.lineWidth = Math.max(1.5, Style.spaceReal(1.5))
              ctx.lineJoin = "round"
              ctx.stroke()
            }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.strokeStyle = Qt.rgba(lineA.r, lineA.g, lineA.b, 0.1)
              ctx.lineWidth = 1
              var marks = [40, 60, 80]
              for (var m = 0; m < marks.length; m++) {
                var y = Math.round(yFor(marks[m])) + 0.5
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke()
              }
              stroke(ctx, gpu, lineB)
              stroke(ctx, cpu, lineA)
            }

            PlainText {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: chart.height - chart.yFor(80) + Style.space(1)
              text: "80°"
              opacity: 0.4
              font.pixelSize: Style.font.caption
            }

            PlainText {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: chart.height - chart.yFor(40) + Style.space(1)
              text: "40°"
              opacity: 0.4
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width
            implicitHeight: legend.implicitHeight

            Row {
              id: legend
              spacing: Style.space(12)
              LegendDot { color: root.fg; label: root.tr("legend.cpu") }
              LegendDot { color: root.gpuLineColor; label: root.tr("legend.gpu") }
            }

            PlainText {
              anchors.right: parent.right
              anchors.verticalCenter: legend.verticalCenter
              text: root.trn("history", root.historyMinutes).arg(root.num(root.historyMinutes, 0))
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- CPU ----------
        Section {
          title: root.tr("section.cpu").arg(root.cpuName)
          fraction: Model.tempFraction(root.readings.cpu_temp, 100)
          tone: root.toneFor("cpu_temp")

          InfoPair { label: root.tr("cpu.package"); value: root.deg(root.readings.cpu_temp); tone: root.toneFor("cpu_temp") }
          InfoPair { label: root.tr("load"); value: root.plain(root.cpuLoad, "%") }
          InfoPair { label: root.tr("cpu.hottestCore"); value: root.deg(root.readings.cpu_core_max); tone: root.toneFor("cpu_core_max") }
          InfoPair { label: root.tr("clock"); value: root.plain(root.readings.cpu_mhz, "MHz") }
          InfoPair { label: root.tr("cpu.memory"); value: root.gib(root.readings.mem_used_mib, root.readings.mem_total_mib) }
        }

        // ---------- GPU ----------
        Section {
          visible: root.readings.gpu_edge !== undefined
          title: root.tr("section.gpu").arg(root.gpuName)
          fraction: Model.tempFraction(root.readings.gpu_junction, 110)
          tone: root.toneFor("gpu_junction")

          InfoPair { label: root.tr("gpu.edge"); value: root.deg(root.readings.gpu_edge); tone: root.toneFor("gpu_edge") }
          InfoPair { label: root.tr("load"); value: root.plain(root.readings.gpu_busy, "%") }
          InfoPair { label: root.tr("gpu.junction"); value: root.deg(root.readings.gpu_junction); tone: root.toneFor("gpu_junction") }
          InfoPair { label: root.tr("gpu.power"); value: root.readings.gpu_power_mw === undefined ? "—" : root.num(root.readings.gpu_power_mw / 1000, 0) + " W" }
          InfoPair { label: root.tr("gpu.memTemp"); value: root.deg(root.readings.gpu_mem); tone: root.toneFor("gpu_mem") }
          InfoPair { label: root.tr("clock"); value: Model.gpuIdle(root.readings) ? root.tr("gpu.idle") : root.plain(root.readings.gpu_sclk_mhz, "MHz") }
          InfoPair { label: root.tr("gpu.vram"); value: root.gib(root.readings.gpu_vram_used_mib, root.readings.gpu_vram_total_mib) }
          InfoPair { label: root.tr("gpu.fan"); value: root.fanText(root.readings.gpu_fan_rpm) }
        }

        // ---------- Cooling ----------
        Section {
          visible: root.readings.cool_liquid !== undefined || root.readings.board_cputin !== undefined
          title: root.tr("section.cooling")
          fraction: Model.tempFraction(root.readings.cool_liquid, 50)
          tone: root.toneFor("cool_liquid")
          showBar: root.readings.cool_liquid !== undefined

          InfoPair { label: root.tr("cool.liquid"); value: root.deg(root.readings.cool_liquid, 1); tone: root.toneFor("cool_liquid") }
          InfoPair { label: root.tr("cool.pump"); value: root.plain(root.readings.cool_pump_rpm, "RPM") }
          InfoPair { label: root.tr("cool.board"); value: root.deg(root.readings.board_cputin); tone: root.toneFor("board_cputin") }
          InfoPair { label: root.tr("cool.fan"); value: root.plain(root.readings.cool_fan_rpm, "RPM") }
          InfoPair { label: "NVMe"; value: root.deg(root.readings.nvme_max); tone: root.toneFor("nvme_max") }
        }

        PanelSeparator { foreground: root.fg }

        Button {
          width: parent.width
          iconText: "󰄪"
          iconSize: Style.font.title
          text: root.tr("openBtop")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          onClicked: root.openBtop()
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

  component HeroTemp: Column {
    property string caption: ""
    property var milli: undefined
    property int tone: -1
    spacing: 0

    PlainText {
      anchors.right: parent.right
      text: root.shortDeg(parent.milli)
      color: parent.tone === 2 ? root.hotColor : root.fg
      font.pixelSize: Style.font.display
      font.bold: true
      Behavior on color { ColorAnimation { duration: Style.duration(200) } }
    }

    PlainText {
      anchors.right: parent.right
      text: parent.caption
      opacity: 0.6
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  component LegendDot: Row {
    property color color
    property string label: ""
    spacing: Style.space(5)

    Rectangle {
      width: Style.space(10)
      height: Style.space(3)
      radius: height / 2
      color: parent.color
      anchors.verticalCenter: parent.verticalCenter
    }

    PlainText {
      text: parent.label
      opacity: 0.6
      font.pixelSize: Style.font.caption
    }
  }

  component Section: Column {
    id: section
    property string title: ""
    property real fraction: 0
    property int tone: -1
    property bool showBar: true
    default property alias pairs: grid.children

    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: section.title
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Item {
      visible: section.showBar
      width: parent.width
      implicitHeight: Style.space(6)

      Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
      }

      Rectangle {
        anchors.left: track.left
        anchors.verticalCenter: track.verticalCenter
        height: track.height
        radius: track.radius
        color: section.tone === 2 ? root.hotColor : root.fg
        width: Math.max(track.height, track.width * section.fraction)
        Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Style.duration(220) } }
      }
    }

    Grid {
      id: grid
      width: parent.width
      columns: 2
      columnSpacing: Style.space(20)
      rowSpacing: Style.spacing.labelGap
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""
    property int tone: -1

    width: (parent.width - Style.space(20)) / 2
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    PlainText {
      id: pairLabel
      anchors.left: parent.left
      anchors.right: pairValue.left
      anchors.rightMargin: Style.space(8)
      text: parent.label
      opacity: 0.6
      elide: Text.ElideRight
      font.pixelSize: Style.font.bodySmall
    }

    PlainText {
      id: pairValue
      anchors.right: parent.right
      text: parent.value
      color: parent.tone === 2 ? root.hotColor : root.fg
      font.bold: parent.tone >= 1
      font.pixelSize: Style.font.bodySmall
    }
  }
}
