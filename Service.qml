import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

// Holds the Gmail state for the bar widget.
//
// Rather than polling, this keeps gmail-watch.py running: that process holds
// one IMAP IDLE connection so Gmail pushes changes to us. The watcher prints
// one JSON object per line, and takes "refresh" on stdin when the user asks
// for an explicit resync — so a manual refresh reuses the open connection
// instead of opening a second one.
Item {
  id: root

  property var settings: ({})

  property bool ok: false
  property bool needsSetup: false
  property string error: ""
  property string account: ""
  property int unread: 0
  property var messages: []
  property string inboxUrl: "https://mail.google.com/mail/u/0/#inbox"
  property bool loading: false
  property double lastUpdated: 0

  readonly property bool hasLoadedOnce: lastUpdated > 0
  readonly property bool connected: watcher.running && hasLoadedOnce
  readonly property int maxMessages: intSetting("maxMessages", 10, 1, 50)

  // Belt and braces for the push connection: if IDLE ever stalls without the
  // socket dropping, leaving a browser still forces a resync. Costs one line
  // on stdin, not a new IMAP connection.
  readonly property string browserClassPattern: String(setting("browserClass",
    "edge|chrome|chromium|brave|firefox|librewolf|zen|vivaldi|opera"))
  property string _lastFocusClass: ""
  property double _lastFocusRefresh: 0

  // A plugin does not get its install path injected, so derive it from this
  // file's own URL instead of hardcoding ~/.config/omarchy/plugins/...
  readonly property string pluginDir: {
    var raw = Qt.resolvedUrl(".").toString()
    if (raw.indexOf("file://") === 0) raw = raw.substring(7)
    return decodeURIComponent(raw)
  }
  readonly property string watchPath: pluginDir + "gmail-watch.py"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function startWatcher() {
    if (watcher.running) return
    watcher.command = ["python3", watchPath, String(maxMessages)]
    watcher.running = true
  }

  function refresh() {
    if (watcher.running) {
      loading = true
      watcher.write("refresh\n")
    } else {
      startWatcher()
    }
  }

  function applyPayload(raw) {
    var line = String(raw || "").trim()
    if (line === "") return

    var parsed = null
    try {
      parsed = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!parsed || typeof parsed !== "object") return

    loading = false
    ok = parsed.ok === true
    needsSetup = parsed.needsSetup === true
    error = String(parsed.error || "")
    if (ok) {
      account = String(parsed.account || "")
      unread = Number(parsed.unread || 0)
      messages = parsed.messages || []
      inboxUrl = String(parsed.inboxUrl || root.inboxUrl)
    } else {
      unread = 0
      messages = []
    }
    lastUpdated = Date.now()
  }

  function openUrl(url) {
    var target = String(url || "")
    if (target === "") return
    Quickshell.execDetached(["omarchy-launch-browser", target])
  }

  function openMessage(message) {
    if (!message) return
    openUrl(message.url || inboxUrl)
  }

  function openInbox() {
    openUrl(inboxUrl)
  }

  function isBrowserClass(cls) {
    if (!cls) return false
    try {
      return new RegExp(browserClassPattern, "i").test(String(cls))
    } catch (e) {
      return false
    }
  }

  function handleHyprlandEvent(event) {
    if (String(event && event.name ? event.name : "") !== "activewindow") return

    var parts
    try {
      parts = event.parse ? event.parse(2) : String(event.data || "").split(",")
    } catch (e) {
      parts = String(event && event.data ? event.data : "").split(",")
    }

    var cls = String(parts[0] || "")
    var previous = _lastFocusClass
    _lastFocusClass = cls
    if (previous === "" || previous === cls) return
    if (!isBrowserClass(previous) || isBrowserClass(cls)) return

    var now = Date.now()
    if (now - _lastFocusRefresh < 8000) return
    _lastFocusRefresh = now
    refresh()
  }

  Component.onCompleted: startWatcher()
  onMaxMessagesChanged: if (watcher.running) watcher.running = false  // restarts with the new cap

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  Process {
    id: watcher
    running: false
    command: []
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.applyPayload(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text !== "") console.warn("gmail watcher: " + text)
      }
    }

    onExited: function(exitCode) {
      root.loading = false
      restartTimer.restart()
    }
  }

  Timer {
    // The watcher reconnects internally; this only covers the process itself
    // dying (crash, or a deliberate restart after a settings change).
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: root.startWatcher()
  }

  Timer {
    // Last-resort watchdog: if the process is somehow gone and no exit fired,
    // bring it back.
    interval: 60000
    repeat: true
    running: true
    onTriggered: if (!watcher.running) root.startWatcher()
  }
}
