# Gmail bar widget

Unread Gmail count in the Omarchy bar, with a dropdown of recent unread
messages that open directly in the browser.

## Install

```bash
omarchy plugin add https://github.com/Harlock123/omarchy-gmail.git --enable --yes
```

That clones the plugin into `~/.config/omarchy/plugins/lwatson.gmail/` and adds
the widget to your bar. Then put the setup command on your `PATH`:

```bash
install -m 0755 ~/.config/omarchy/plugins/lwatson.gmail/bin/omarchy-gmail-setup ~/.local/bin/
```

Update later with `omarchy plugin update lwatson.gmail`, remove with
`omarchy plugin remove lwatson.gmail`.

### Requirements

- Omarchy 4.x (the Quickshell-based shell)
- Python 3 (standard library only — no pip packages)
- `secret-tool` (libsecret) for storing the app password in your keyring
- A Google account with 2-Step Verification enabled, so app passwords are available

## Setup

```bash
omarchy-gmail-setup            # connect an account
omarchy-gmail-setup --status   # show config + fetch a live sample
omarchy-gmail-setup --remove   # forget the account
```

You need a Google **app password** (not your account password), created at
<https://myaccount.google.com/apppasswords>. That page only appears when
2-Step Verification is enabled on the account.

The password is stored in the login keyring (`service=omarchy-gmail`).
Only the address and account index are written to `~/.config/omarchy/gmail.json`.

## Interactions

| Action | Result |
|---|---|
| Left click | open/close the dropdown |
| Right click | refresh now |
| Middle click | open the Gmail inbox |
| Click a message | open that thread in the browser |
| `j`/`k` or arrows | move the cursor |
| `Enter` | open the selected message |
| `r` | refresh |
| `g` | open the inbox |
| `Esc` | close |

## Settings

Set these inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "lwatson.gmail", "maxMessages": 10, "hideWhenEmpty": false }
```

- `maxMessages` — rows in the dropdown, 1–50 (default 10)
- `hideWhenEmpty` — hide the icon entirely when nothing is unread
- `browserClass` — regex of browser window classes for the focus hook below

## Staying current

There is no polling. `gmail-watch.py` runs for the life of the shell, holding a
single authenticated IMAP connection in **IDLE**, which is the IMAP command
that asks the server to push changes instead of being asked. New mail, a
message read on your phone, a thread archived in the web UI — Gmail reports it
on that open connection and the badge follows within a second or so.

Mechanics worth knowing:

- **IDLE is renewed every 5 minutes.** RFC 2177 allows up to 29; the shorter
  window keeps the connection provably alive and doubles as a backstop resync
  if a push is ever missed.
- **Any untagged server line triggers a full resync.** New mail arrives as
  `EXISTS`, flag changes elsewhere as `FETCH`, deletions as `EXPUNGE` — the
  watcher re-reads state rather than parsing which it was, so there is no
  category of update it can misinterpret.
- **Manual refresh reuses the same connection.** The widget writes `refresh`
  to the watcher's stdin instead of opening a second IMAP session.
- **Reconnects back off** 2s → 60s, and a transient failure stays silent: the
  UI only shows an error after two consecutive failures, so a brief network
  blip does not flash the icon red.
- **The shell restarts the watcher** within ~3s if the process dies, with a
  60s watchdog behind that.
- **Focus hook** (belt and braces): leaving a browser window forces a resync,
  in case IDLE ever stalls without the socket dropping. Debounced to once
  every 8s. Configurable via `browserClass`.

Idle cost is a held TCP connection: 0% CPU, ~27 MB RSS.

## How it works

`gmail_imap.py` holds the shared IMAP logic. `gmail-watch.py` uses it to run
the long-lived IDLE connection, printing one JSON object per line;
`Service.qml` reads those lines and `Panel.qml` renders them.
`gmail-fetch.py` is a one-shot wrapper over the same module, used by
`omarchy-gmail-setup --status` and for debugging by hand. The badge counts
the whole unread mailbox, while the list is capped at `maxMessages`.

Deep links come from Gmail's `X-GM-THRID` IMAP extension: the hex form of that
thread id is exactly what the Gmail web UI uses, so `#inbox/<hex>` lands on the
message itself rather than on a search page. Messages are opened with
`omarchy-launch-browser`, which also focuses the browser window.

The one-shot helper always prints valid JSON and exits 0 — failures arrive as
`{"ok": false, "error": ...}` so the widget can render an error state instead
of guessing from an exit code.

## Development note

`omarchy-shell shell rescanPlugins` reloads plugin *code*, but an already-open
KeyboardPanel surface keeps rendering the previous build. After editing QML,
run `omarchy restart shell` before judging the result — otherwise you are
looking at a stale panel.

## Files

| File | Role |
|---|---|
| `gmail_imap.py` | Shared: config, credential, connect, snippet extraction, state fetch |
| `gmail-watch.py` | Long-running IDLE watcher; emits JSONL, takes `refresh` on stdin |
| `gmail-fetch.py` | One-shot JSON, for `--status` and debugging |
| `Service.qml` | Owns the watcher process and the parsed state |
| `Panel.qml` | Bar button and dropdown |
| `GmailIcon.qml` | Envelope + unread badge |
| `Model.js` | Formatting helpers |
