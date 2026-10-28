# AGENTS.md

Notes for anyone, human or AI agent, changing this code. `README.md` covers installing, setup, the widget's
interactions and how IMAP IDLE keeps it current; this file covers how the pieces fit and the rules that keep it
working.

## What this is

An Omarchy 4.x bar-widget plugin (id `harlock123.gmail`, see `manifest.json`) that shows the unread Gmail count and
a dropdown of recent unread messages. The UI is QML for Omarchy's Quickshell-based shell; the mail side is Python 3
using only the standard library, talking IMAP with a Google app password. It runs only on Linux under Omarchy.

## Commands

There is no build step and there are no tests yet. To try changes by hand:

```bash
python3 gmail-fetch.py 10        # one-shot: prints one JSON object (the state, or an error) and exits 0
python3 gmail-watch.py 10        # the long-running watcher: JSON lines on stdout; type "refresh" on stdin
bin/omarchy-gmail-setup          # connect an account; --status shows the config and a live sample, --remove forgets it
omarchy restart shell            # after editing QML: rescanPlugins alone leaves an open panel on the old build
```

The number is the maximum messages to list, clamped to 0..50 (default 10).

## Layout

- `manifest.json`: the plugin manifest. Declares `Panel.qml` as the bar-widget entry point and the settings schema
  (`maxMessages`, `hideWhenEmpty`, `browserClass`) with their defaults.
- `Panel.qml`: the bar button and the dropdown, with mouse and keyboard handling. It creates the `Service`.
- `Service.qml`: owns the watcher `Process` (`python3 gmail-watch.py <maxMessages>`), parses its JSON lines, writes
  `refresh` to its stdin, restarts it after 3 s if it dies, and runs a 60 s watchdog and the browser focus hook.
- `GmailIcon.qml`: the envelope with the unread badge.
- `Model.js`: pure formatting helpers (`timeAgo`, `senderLabel`, `summaryTooltip`, `emptyStateText`).
- `gmail_imap.py`: shared Python. Reads `~/.config/omarchy/gmail.json`, looks the password up with `secret-tool`
  (`service omarchy-gmail`), falling back to `~/.config/omarchy/gmail-password`. Connects, extracts snippets and builds
  the state (`fetch_state`) and error (`error_payload`) objects.
- `gmail-watch.py`: holds one IMAP IDLE connection, resyncs on any server line, and emits a line only when the state
  changes. It backs off 2 s to 60 s on reconnect and stays quiet until two failures in a row.
- `gmail-fetch.py`: a one-shot wrapper over `gmail_imap.collect`.
- `bin/omarchy-gmail-setup`: a Bash script that stores the app password in the keyring and writes the config.

## Rules that keep it working

- **The JSON contract.** `Service.qml` reads the keys built in `gmail_imap.py`: `ok`, `error`, `needsSetup`,
  `account`, `unread`, `shown`, `inboxUrl` and `messages` (each with `uid`, `from`, `fromEmail`, `subject`,
  `snippet`, `timestamp` and `url`). Change both sides together, and keep `error_payload` the same shape as a
  success.
- **Never fail by exit code.** The Python scripts report failures as `{"ok": false, ...}` and `gmail-fetch.py`
  always exits 0, so the widget can show an error state.
- **One line per object.** The watcher writes each payload as a single JSON line and flushes it; anything else on
  stdout breaks the parser.
- **Standard library only.** No pip packages: the plugin is installed by cloning and run with the system `python3`.
- **No hardcoded install path.** `Service.qml` finds `gmail-watch.py` from its own URL (`pluginDir`), because the
  shell does not pass a plugin its location. Only the setup script assumes
  `~/.config/omarchy/plugins/harlock123.gmail/`.
- **Secrets stay out of the repo and the config.** Only the address and account index go into `gmail.json`; the app
  password lives in the keyring.
- **Deep links.** Message URLs use the hex form of Gmail's `X-GM-THRID`, which is what the Gmail web UI uses.
- **`bin/omarchy-gmail-setup` is tracked** even though `.gitignore` lists its name, so edits to it show up in git
  as normal.

## Making a change

- Test against a real account: run `gmail-fetch.py`, then the watcher, then restart the shell and check the widget.
- A new setting goes in `manifest.json` (both `defaults` and `schema`) and is read in QML with `setting(...)` or
  `intSetting(...)`; document it in `README.md`.

## CI and releases

There is no CI workflow. Users install and update straight from the repository with `omarchy plugin add` and
`omarchy plugin update`.
