.pragma library

// Compact relative age, e.g. "now", "12m", "3h", "2d", "5 Aug".
function timeAgo(timestampSeconds, nowMs) {
  var ts = Number(timestampSeconds || 0)
  if (!isFinite(ts) || ts <= 0) return ""

  var now = Number(nowMs || Date.now())
  var deltaSec = Math.floor((now - ts * 1000) / 1000)
  if (deltaSec < 0) deltaSec = 0

  if (deltaSec < 60) return "now"
  if (deltaSec < 3600) return Math.floor(deltaSec / 60) + "m"
  if (deltaSec < 86400) return Math.floor(deltaSec / 3600) + "h"
  if (deltaSec < 604800) return Math.floor(deltaSec / 86400) + "d"

  var date = new Date(ts * 1000)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return date.getDate() + " " + months[date.getMonth()]
}

// Short sender label — strip a trailing quoted-address remnant and collapse
// "Last, First" style names that some senders use.
function senderLabel(message) {
  if (!message) return ""
  var name = String(message.from || "").replace(/^["']|["']$/g, "").trim()
  if (name === "") name = String(message.fromEmail || "").trim()
  return name === "" ? "(unknown sender)" : name
}

function summaryTooltip(service) {
  if (!service) return "Gmail"
  if (service.needsSetup) return "Gmail — run omarchy-gmail-setup"
  if (!service.ok) return "Gmail — " + (service.error || "unavailable")
  var count = Number(service.unread || 0)
  var noun = count === 1 ? "unread message" : "unread messages"
  var who = service.account ? " · " + service.account : ""
  return count + " " + noun + who
}

function emptyStateText(service) {
  if (!service) return "Loading…"
  if (service.needsSetup) return "Gmail is not set up yet."
  if (!service.ok) return service.error || "Could not reach Gmail."
  if (!service.hasLoadedOnce) return "Loading…"
  return "Inbox zero. Nothing unread."
}
