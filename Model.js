// Parsing and formatting for the netscan bar widget.
//
// netscan --json is the single source of truth for discovery; this file only
// turns its output into rows the panel can render. Kept separate from the
// QML so it can be exercised directly by test/run without a shell.

function emptyResult() {
  return { iface: "", network: "", count: 0, self: {}, devices: [] }
}

// netscan writes a single JSON object, but a scan killed mid-write (a closed
// panel, a rescan already in flight) can leave a truncated tail on stdout.
// Returning the empty result on a parse failure keeps the panel showing its
// last good data rather than blanking out on a transient error.
function parseScan(raw) {
  if (typeof raw !== "string") return emptyResult()
  var text = raw.trim()
  if (text === "") return emptyResult()

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return emptyResult()
  }
  if (!parsed || !Array.isArray(parsed.devices)) return emptyResult()
  return parsed
}

// The label a row shows when the device never announced a name: the vendor
// is more informative than a bare address, and the address is already in its
// own column.
function deviceLabel(device) {
  if (!device) return "Unknown device"
  if (device.name && device.name !== "") return device.name
  if (device.vendor && device.vendor !== "") return device.vendor
  return "Unnamed device"
}

// A device is "known" when it named itself over mDNS/DNS. Randomised MACs
// (phones on private Wi-Fi addresses) are the ones that stay unnamed, and
// they are worth flagging so an unfamiliar entry is not mistaken for a
// roommate's laptop.
function deviceConfidence(device) {
  if (!device) return "unknown"
  if (device.name && device.name !== "") return "named"
  if (device.vendor && device.vendor !== "") return "vendor"
  return "anonymous"
}

// Shown in the hero line while a scan is still running.
function summaryText(result, scanning) {
  if (scanning) return "Scanning…"
  if (!result || result.count === 0) return "No devices"
  return result.count === 1 ? "1 device" : result.count + " devices"
}

// "192.168.0.0/24" from "192.168.0.0", for the panel subtitle.
function networkLabel(result) {
  if (!result || !result.network) return ""
  return result.network
}

// ---- cache -------------------------------------------------------------

// The cache file holds the last scan and the last port result per host, so
// the panel can open with a list already in place. A missing, empty or
// truncated file is not an error -- the panel simply starts empty.
function parseCache(raw) {
  if (typeof raw !== "string") return null
  var text = raw.trim()
  if (text === "") return null

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  return parsed
}

// ---- port scan ---------------------------------------------------------

function emptyPortResult() {
  return { ip: "", ports: [], elapsed_ms: 0, scanned: 0 }
}

// Same contract as parseScan: a scan killed mid-write leaves truncated JSON,
// and the caller keeps its last good result rather than blanking.
function parsePorts(raw) {
  if (typeof raw !== "string") return emptyPortResult()
  var text = raw.trim()
  if (text === "") return emptyPortResult()

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return emptyPortResult()
  }
  if (!parsed || !Array.isArray(parsed.ports)) return emptyPortResult()
  return parsed
}

// "32400" renders as "plex"; a port with no service in /etc/services still
// needs a label, so it falls back to the number rather than an empty row.
function portLabel(port) {
  if (!port) return "—"
  if (port.service && port.service !== "") return port.service
  return "puerto " + port.port
}

function portSummaryText(result) {
  if (!result) return ""
  var count = Array.isArray(result.ports) ? result.ports.length : 0
  if (count === 0) return "No open ports"
  if (count === 1) return "1 open port"
  return count + " open ports"
}

// Some ports identify a device better than its mDNS name does -- a NAS, a
// printer, a game console. These are the fingerprints worth surfacing; a
// match is a hint, not proof, and the UI presents it as one.
var DEVICE_HINTS = [
  { port: 445, label: "Windows / Samba file sharing" },
  { port: 631, label: "Printer (IPP)" },
  { port: 9100, label: "Printer (raw)" },
  { port: 515, label: "Printer (LPD)" },
  { port: 32400, label: "Plex media server" },
  { port: 6600, label: "Music daemon (LMS/Mpd)" },
  { port: 3389, label: "Remote desktop (RDP)" },
  { port: 5900, label: "Screen sharing (VNC)" },
  { port: 5432, label: "PostgreSQL" },
  { port: 3306, label: "MySQL / MariaDB" },
  { port: 6379, label: "Redis" },
  { port: 27017, label: "MongoDB" },
  { port: 9000, label: "Sonarr / Portainer / PHP-FPM" },
  { port: 8096, label: "Jellyfin" }
]

function deviceGuess(ports) {
  if (!Array.isArray(ports) || ports.length === 0) return ""
  var found = []
  for (var i = 0; i < ports.length; i++) {
    var entry = ports[i]
    for (var j = 0; j < DEVICE_HINTS.length; j++) {
      if (DEVICE_HINTS[j].port === entry.port) {
        var label = DEVICE_HINTS[j].label
        if (found.indexOf(label) === -1) found.push(label)
      }
    }
  }
  if (found.length === 0) return ""
  return found.length === 1 ? found[0] : found.length + " device hints"
}