import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Fing-style LAN discovery in the bar. The widget shows the device count and
// opens a list; `netscan --json` does the actual discovery, so the shell
// never runs a scan on its own -- it refreshes when the panel opens and on
// demand, which keeps a multi-second sweep off the bar's startup path.
//
// The scan runs as a normal user process: the ping sweep needs only the
// setuid bit on ping, and the neighbour table is world-readable.
Panel {
  id: root
  moduleName: "stylder.netscan"
  ipcTarget: "stylder.netscan"
  manageIpc: false

  property var scanResult: Model.emptyResult()
  property bool scanning: false
  // Guards against a scan outliving the panel: a dismissal kills the process,
  // but its buffered output can still land afterwards and would repopulate a
  // panel the user already closed. The flag survives onExited because the
  // exit and stream-finished signals have no guaranteed order.
  property bool expectedStop: false
  property bool netscanMissing: false
  property string errorText: ""

  // ---- port detail ----
  // Selecting a row opens its port list over the device list. `null` means
  // the list is showing.
  property var selectedDevice: null
  property var portResult: Model.emptyPortResult()
  property bool portScanning: false
  property bool portExpectedStop: false

  // ---- clipboard ----
  // The last value copied, so the button that copied it can show a tick for
  // a moment. Cleared again when the feedback timer fires.
  property string copiedValue: ""

  // ---- cache ----
  // The last scan is written to disk so the panel opens with the previous
  // list already in place. The sweep takes a second or two, and a device
  // that was there a minute ago is more useful than an empty list. The live
  // scan replaces it once it lands.
  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/omarchy/netscan.json"
  // Port results of every host that has been opened, keyed by address.
  property var cachedPorts: ({})

  readonly property int refreshSeconds: Math.max(30, setting("refreshSeconds", 120))

  // The scanner ships with the plugin, so a clone of it works on its own.
  // The script sits next to this file, and the panel runs it by the path it
  // resolves to; a plugin loaded from somewhere that cannot be turned back
  // into a filesystem path falls back to the copy on PATH.
  readonly property var netscanCommand: {
    var url = String(Qt.resolvedUrl("bin/netscan"))
    var marker = url.indexOf("://")
    var path = marker === -1 ? "" : url.substring(marker + 3)
    try { path = decodeURIComponent(path) } catch (e) { }
    if (path.startsWith("/")) return ["bash", path]
    return ["netscan"]
  }

  readonly property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.55)
  readonly property color selectedFill: bar ? Style.selectedFillFor(barForeground, Commons.Color.accent) : "transparent"
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent

  readonly property var devices: scanResult && Array.isArray(scanResult.devices) ? scanResult.devices : []
  readonly property bool hasData: devices.length > 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function scan() {
    // A second request while one is in flight: let the running scan land
    // rather than stacking overlapping sweeps on the same interface.
    if (scanProc.running) return
    root.errorText = ""
    root.netscanMissing = false
    root.expectedStop = false
    root.scanning = true
    scanProc.command = root.netscanCommand.concat(["--json"])
    scanProc.running = true
  }

  function stopScan() {
    if (scanProc.running) {
      root.expectedStop = true
      scanProc.running = false
    }
    root.scanning = false
  }

  // Shown when the scanner could not be run at all -- usually a plugin
  // folder that was copied without its bin/ directory.
  function missingHelperText() {
    return "netscan could not be run. It ships with this plugin in bin/netscan -- reinstall the plugin, or put netscan on your PATH."
  }

  function applyOutput(raw) {
    var parsed = Model.parseScan(raw)
    // An empty result means the JSON never arrived (killed mid-write, or a
    // helper that failed before printing anything). Keep the previous good
    // scan on screen rather than blanking the panel.
    if (parsed.devices.length === 0 && parsed.count === 0 && root.hasData) return
    root.scanResult = parsed
    if (parsed.count > 0) root.errorText = ""
    root.saveCache()
  }

  // ---- cache ----

  // Restores the last scan from disk. Only used when there is nothing on
  // screen yet: a live scan that has already landed is newer than the
  // file, and the file must not overwrite it.
  function applyCache(raw) {
    var parsed = Model.parseCache(raw)
    if (!parsed) return

    if (!root.hasData && parsed.scan && Array.isArray(parsed.scan.devices)
        && parsed.scan.devices.length > 0) {
      root.scanResult = parsed.scan
    }
    if (parsed.ports && typeof parsed.ports === "object") {
      // Merged, not replaced: a port scan that landed while the file was
      // still being read is newer than the file.
      for (var ip in parsed.ports) {
        if (!(ip in root.cachedPorts)) root.cachedPorts[ip] = parsed.ports[ip]
      }
    }
  }

  function saveCache() {
    var payload = {
      ports: root.cachedPorts,
      saved_at: new Date().toISOString()
    }
    // A scan that found nothing does not erase what is already known: a
    // device that is asleep is still a device on the network.
    if (root.scanResult && Array.isArray(root.scanResult.devices)
        && root.scanResult.devices.length > 0) {
      payload.scan = root.scanResult
    }
    cacheFile.setText(JSON.stringify(payload))
  }

  // ---- device selection ----

  function openDevice(device) {
    if (!device) return
    root.selectedDevice = device
    // The ports of the last visit are on screen straight away; the scan
    // that follows replaces them with the current ones.
    var cached = root.cachedPorts[device.ip]
    root.portResult = cached ? cached : Model.emptyPortResult()
    root.scanPorts()
  }

  function closeDevice() {
    stopPortScan()
    root.selectedDevice = null
    root.portResult = Model.emptyPortResult()
  }

  // A connect scan of the common port set is sub-second on a LAN, so it runs
  // on selection with no progress beyond a spinner. The full 65535 range is
  // available from the CLI (`netscan --ports <ip> --full`) but takes about a
  // minute, which is too long to hold a panel open for.
  function scanPorts() {
    if (!root.selectedDevice) return
    if (portProc.running) return
    root.portExpectedStop = false
    root.portScanning = true
    portProc.command = root.netscanCommand.concat(["--ports", String(root.selectedDevice.ip), "--json"])
    portProc.running = true
  }

  function stopPortScan() {
    if (portProc.running) {
      root.portExpectedStop = true
      portProc.running = false
    }
    root.portScanning = false
  }

  function applyPortOutput(raw) {
    var parsed = Model.parsePorts(raw)
    // Keep the previous device's ports visible if this scan produced nothing
    // parseable, rather than flashing an empty list.
    if (parsed.ip === "" && Array.isArray(root.portResult.ports) && root.portResult.ports.length > 0) return
    root.portResult = parsed
    if (parsed.ip !== "") {
      root.cachedPorts[parsed.ip] = parsed
      root.saveCache()
    }
  }

  // ---- clipboard ----

  // Copies a value to the clipboard. The text is passed as an argument
  // rather than on stdin: wl-copy only reads stdin when it has no text to
  // copy, and a QML process has no way to close the pipe. wl-copy keeps
  // serving the selection from a background process, so it can be started
  // and forgotten.
  function copyText(text) {
    if (!text) return
    copyProc.command = ["wl-copy", "--type", "text/plain;charset=utf-8", "--", text]
    copyProc.running = true
    root.copiedValue = text
    copyFeedbackTimer.restart()
  }

  Component.onCompleted: refreshTimer.start()

  // Opening is the natural moment to refresh: it is when the user is
  // actually looking at the list. The base Panel owns open/close/toggle, so
  // this hook is where the scan and the in-flight cleanup hang off.
  onOpenedChanged: if (opened) {
    root.scan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    // Leaving the panel abandons any in-flight work: a port scan was started
    // for a detail view nobody is looking at any more, and the device sweep
    // is redone the next time the panel opens.
    root.stopPortScan()
    root.stopScan()
    root.selectedDevice = null
  }

  Timer {
    id: refreshTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    onTriggered: if (root.opened && !root.scanning) root.scan()
  }

  // How long the copy button shows its tick before going back to the copy
  // glyph.
  Timer {
    id: copyFeedbackTimer
    interval: 1500
    onTriggered: root.copiedValue = ""
  }

  Process {
    id: copyProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = "Could not copy to the clipboard"
    }
  }

  // The scan cache. Read once at startup, written after every scan, and
  // not watched: the file belongs to this widget alone.
  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyCache(text())
    onLoadFailed: function(error) {
      // A missing cache is the normal first run, not a problem.
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.expectedStop) root.applyOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.expectedStop) root.errorText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.scanning = false
      if (root.expectedStop) return
      // Exit 127 is the shell's "command not found"; netscan itself exits 1
      // for a missing interface and prints why on stderr.
      if (exitCode === 127) root.netscanMissing = true
      else if (exitCode !== 0 && root.errorText === "")
        root.errorText = "netscan exited with status " + exitCode
      root.expectedStop = false
    }
  }

  Process {
    id: portProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.portExpectedStop) root.applyPortOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.portExpectedStop) root.errorText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.portScanning = false
      if (root.portExpectedStop) return
      // A host with no open ports exits 0 with an empty list -- that is a
      // result, not a failure. A non-zero exit means the scan could not run
      // (no route, no nc), and stderr already carries the reason.
      if (exitCode !== 0 && root.errorText === "")
        root.errorText = "Port scan failed with status " + exitCode
      root.portExpectedStop = false
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.controller.show() }
    function close(): void { root.controller.hide() }
    function show(): void { root.controller.show() }
    function hide(): void { root.controller.hide() }
    function toggle(): void { root.controller.toggle() }
    function refresh(): void {
      if (root.selectedDevice !== null) root.scanPorts()
      else root.scan()
    }
    function status(): string {
      return JSON.stringify({
        count: root.devices.length,
        scanning: root.scanning,
        network: Model.networkLabel(root.scanResult),
        missing: root.netscanMissing,
        selectedIp: root.selectedDevice ? root.selectedDevice.ip : null,
        openPorts: root.portResult.ports.length,
        portScanning: root.portScanning
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰍷"
          color: root.hasData ? root.barForeground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(11)
        }
        // Count badge. Hidden while scanning so the bar does not flicker a
        // stale number through every refresh.
        Rectangle {
          visible: root.hasData && !root.scanning
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(2)
          anchors.bottomMargin: Style.space(1)
          width: badgeLabel.implicitWidth + Style.space(5)
          height: badgeLabel.implicitHeight
          radius: height / 2
          color: root.barForeground

          Text {
            id: badgeLabel
            anchors.centerIn: parent
            text: root.devices.length > 99 ? "99+" : String(root.devices.length)
            // The badge is drawn in the bar's foreground colour, so the
            // count needs the background colour on top of it. The bar
            // exposes no background property of its own.
            color: Commons.Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
    tooltipText: root.hasData
      ? Model.summaryText(root.scanResult, false) + " on " + Model.networkLabel(root.scanResult)
      : "Scan the local network"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.scan()
      else root.controller.toggle()
    }
  }

  // ---- panel ----

  PanelWindow {
    id: panelWindow
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "stylder-netscan"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.6)

      MouseArea {
        anchors.fill: parent
        onClicked: root.controller.hide()
      }
    }

    Item {
      id: keyCatcher
      anchors.centerIn: parent
      width: Math.min(Style.space(720), panelWindow.width - Style.space(64))
      height: Math.min(Style.space(560), panelWindow.height - Style.space(64))
      focus: true

      // Esc steps back out of a device before it closes the panel, so a
      // drill-down is never a dead end.
      Keys.onEscapePressed: root.selectedDevice !== null
        ? root.closeDevice()
        : root.controller.hide()
      Keys.onReturnPressed: root.selectedDevice !== null ? root.scanPorts() : root.scan()
      Keys.onSpacePressed: root.selectedDevice !== null ? root.scanPorts() : root.scan()

      Rectangle {
        anchors.fill: parent
        color: Commons.Color.background
        radius: Style.cornerRadius * 1.5
        border.width: 1
        border.color: Qt.darker(Commons.Color.background, 1.4)

        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(20)
          spacing: Style.space(14)

          // ---- header ----

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Text {
              text: "󰍷  Network scan"
              color: Commons.Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Item { Layout.fillWidth: true }

            Text {
              visible: root.scanning
              text: "Scanning…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.scanning && root.hasData
              text: Model.networkLabel(root.scanResult) + "  ·  " + Model.summaryText(root.scanResult, false)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator {}

          // ---- messages ----

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            visible: root.netscanMissing || root.errorText !== ""

            Text {
              Layout.fillWidth: true
              visible: root.netscanMissing
              text: root.missingHelperText()
              color: root.urgentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              Layout.fillWidth: true
              visible: !root.netscanMissing && root.errorText !== ""
              text: root.errorText
              color: root.urgentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---- empty state ----

          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(8)
            visible: !root.hasData && root.errorText === "" && !root.netscanMissing

            Item { Layout.fillHeight: true }

            Text {
              Layout.fillWidth: true
              text: root.scanning ? "Looking for devices…" : "No devices found"
              color: Commons.Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: "Press Enter to scan again"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Item { Layout.fillHeight: true }
          }

          // ---- device list ----

          ListView {
            id: deviceList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.hasData && root.selectedDevice === null
            clip: true
            spacing: Style.space(4)
            model: root.devices
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar {
              policy: deviceList.contentHeight > deviceList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
              anchors.right: parent.right
            }

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property bool hovered: hoverArea.containsMouse
              // The address on its own, for a terminal or a browser.
              readonly property string address: row.modelData.ip

              function copyAddress() {
                root.copyText(row.address)
              }
              // Named devices earn the accent; anonymous ones stay muted so
              // a randomised-MAC neighbour is easy to tell from a real one.
              readonly property color rowColor: row.hovered
                ? root.selectedFill
                : (Model.deviceConfidence(row.modelData) === "named"
                  ? "transparent"
                  : Qt.rgba(Commons.Color.foreground.r,
                            Commons.Color.foreground.g,
                            Commons.Color.foreground.b, 0.03))

              width: deviceList.width - Style.space(8)
              height: Style.space(46)
              radius: Style.cornerRadius
              color: row.rowColor

              MouseArea {
                id: hoverArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDevice(row.modelData)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(12)

                Rectangle {
                  Layout.alignment: Qt.AlignVCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: row.modelData.state === "REACHABLE" ? root.barForeground : root.dim
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    Layout.fillWidth: true
                    text: Model.deviceLabel(row.modelData)
                    color: Commons.Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    // The address is always shown; the vendor is extra
                    // context once the OUI database is available. The
                    // neighbour state is deliberately left out -- it describes
                    // the kernel's ARP cache, not the device, and "delay"
                    // reads to a user like something is wrong with it.
                    text: row.modelData.ip
                      + (row.modelData.vendor ? "  ·  " + row.modelData.vendor : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: row.modelData.mac
                  color: root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                }

                // Copy the address on its own -- the thing you paste into
                // a terminal, a browser or another scanner.
                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: root.copiedValue === row.address ? "󰄬" : "󰐎"
                  color: copyIpArea.containsMouse ? Commons.Color.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: copyIpArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: row.copyAddress()
                  }
                }

                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: "󰅂"
                  color: hoverArea.containsMouse ? Commons.Color.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ---- device detail: open ports ----

          ColumnLayout {
            id: portView
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.selectedDevice !== null
            spacing: Style.space(10)

            // Back button plus the selected device's identity, so it is
            // always clear which host the ports belong to.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                text: "󰅃"
                color: backArea.containsMouse ? Commons.Color.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: backArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeDevice()
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                  Layout.fillWidth: true
                  text: root.selectedDevice ? Model.deviceLabel(root.selectedDevice) : ""
                  color: Commons.Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: root.selectedDevice
                    ? root.selectedDevice.ip
                      + (root.selectedDevice.mac ? "  ·  " + root.selectedDevice.mac : "")
                    : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                visible: !root.portScanning && root.portResult.ports.length > 0
                text: Model.portSummaryText(root.portResult)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              // The device list is hidden while the ports are showing, so
              // the plain address needs a button of its own here.
              Text {
                Layout.alignment: Qt.AlignVCenter
                text: root.selectedDevice
                  ? (root.copiedValue === root.selectedDevice.ip ? "󰄬" : "󰐎")
                  : ""
                color: copyHeaderIpArea.containsMouse ? Commons.Color.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: copyHeaderIpArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.selectedDevice) root.copyText(root.selectedDevice.ip)
                }
              }
            }

            // A recognised service can identify the device more precisely
            // than its hostname does. Framed as a hint, not a verdict.
            Rectangle {
              Layout.fillWidth: true
              visible: !root.portScanning
                && root.portResult.ports.length > 0
                && Model.deviceGuess(root.portResult.ports) !== ""
              height: hintLabel.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Qt.rgba(Commons.Color.accent.r,
                              Commons.Color.accent.g,
                              Commons.Color.accent.b, 0.12)

              Text {
                id: hintLabel
                anchors.fill: parent
                anchors.margins: Style.space(8)
                text: root.portResult.ports.length > 0
                  ? "󰋼  Likely: " + Model.deviceGuess(root.portResult.ports)
                  : ""
                color: Commons.Color.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            // Scanning / empty / results, one of which is always on screen.
            Text {
              Layout.fillWidth: true
              visible: root.portScanning
              text: "Scanning ports…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              Layout.fillHeight: true
              verticalAlignment: Text.AlignVCenter
            }

            Text {
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: !root.portScanning && root.portResult.ports.length === 0
              text: "No open TCP ports"
              color: Commons.Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }

            ListView {
              id: portList
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: !root.portScanning && root.portResult.ports.length > 0
              clip: true
              spacing: Style.space(2)
              model: root.portResult.ports
              boundsBehavior: Flickable.StopAtBounds

              ScrollBar {
                policy: portList.contentHeight > portList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                anchors.right: parent.right
              }

              delegate: Rectangle {
                id: portRow
                required property var modelData
                width: portList.width - Style.space(8)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: "transparent"

                // The full address of this port on this host: what a
                // browser, an SSH client or a scanner wants.
                readonly property string address: root.selectedDevice
                  ? root.selectedDevice.ip + ":" + portRow.modelData.port
                  : ""

                function copyAddress() {
                  root.copyText(portRow.address)
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(12)

                  Text {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Style.space(64)
                    text: String(portRow.modelData.port)
                    color: Commons.Color.foreground
                    font.family: "monospace"
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    text: Model.portLabel(portRow.modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  // Copy the address with the port included.
                  Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.copiedValue === portRow.address ? "󰄬" : "󰐎"
                    color: copyAddressArea.containsMouse ? Commons.Color.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall

                    MouseArea {
                      id: copyAddressArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(6)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: portRow.copyAddress()
                    }
                  }
                }
              }
            }

            Text {
              Layout.fillWidth: true
              visible: !root.portScanning && root.portResult.ports.length > 0
              text: root.portResult.elapsed_ms + " ms · "
                + root.portResult.scanned + " ports checked · Enter rescan"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ---- footer ----

          Text {
            Layout.fillWidth: true
            text: root.selectedDevice !== null
              ? "Enter rescan ports  ·  Esc back"
              : "Enter rescan  ·  Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}