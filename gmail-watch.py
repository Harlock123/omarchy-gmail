#!/usr/bin/env python3
"""Long-running Gmail watcher using IMAP IDLE.

Holds one authenticated connection to Gmail and asks the server to push
notifications instead of polling. Emits one JSON object per line on stdout
(the same shape gmail-fetch.py prints) whenever the unread state changes.

Reads simple commands on stdin, one per line:
    refresh   resync and emit now

Usage: gmail-watch.py [max_messages]
"""

import imaplib
import json
import os
import select
import signal
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import gmail_imap

# RFC 2177 says a client must renew IDLE at least every 29 minutes. Five
# minutes keeps the connection demonstrably alive and doubles as a backstop
# resync in case a push is ever missed.
IDLE_WINDOW = 300
DONE_TIMEOUT = 10
BACKOFF_START = 2
BACKOFF_MAX = 60
# Don't flap the UI red on a momentary network blip.
FAILURES_BEFORE_REPORTING = 2

_running = True

# Python restarts an interrupted select() (PEP 475), so a signal handler that
# only flips a flag can leave us blocked for the rest of the timeout. Route
# signals through a self-pipe that select() watches, so shutdown is immediate.
_wake_r, _wake_w = os.pipe()
os.set_blocking(_wake_r, False)
os.set_blocking(_wake_w, False)
signal.set_wakeup_fd(_wake_w)


def _stop(signum, frame):
    global _running
    _running = False


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def _drain_wake():
    try:
        while os.read(_wake_r, 4096):
            pass
    except (BlockingIOError, OSError):
        pass


def emit(payload):
    try:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()
        return True
    except (BrokenPipeError, ValueError):
        # The shell went away; nothing left to report to.
        return False


def signature(payload):
    """What counts as a change worth telling the UI about."""
    return (
        payload.get("ok"),
        payload.get("unread"),
        payload.get("error"),
        tuple(m.get("uid") for m in payload.get("messages", [])),
    )


def start_idle(imap):
    tag = imap._new_tag()
    imap.send(tag + b" IDLE\r\n")
    line = imap.readline()
    if not line.startswith(b"+"):
        raise RuntimeError("server refused IDLE: %r" % line[:80])
    return tag


def stop_idle(imap, tag):
    imap.send(b"DONE\r\n")
    deadline = time.time() + DONE_TIMEOUT
    while time.time() < deadline:
        line = imap.readline()
        if not line:
            raise ConnectionError("connection closed while ending IDLE")
        if line.startswith(tag):
            return
    raise RuntimeError("timed out ending IDLE")


def idle_once(imap, stdin_open):
    """Idle until something happens. Returns why we stopped."""
    tag = start_idle(imap)
    sock = imap.socket()
    deadline = time.time() + IDLE_WINDOW
    reason = "renew"

    try:
        while _running:
            remaining = deadline - time.time()
            if remaining <= 0:
                break

            watch = [sock, _wake_r]
            if stdin_open:
                watch.append(sys.stdin)
            readable, _, _ = select.select(watch, [], [], min(remaining, 30))

            if _wake_r in readable:
                _drain_wake()
                if not _running:
                    return "stopped"

            if sock in readable:
                line = imap.readline()
                if not line:
                    raise ConnectionError("server closed the connection")
                # Any untagged line means mailbox state moved (EXISTS on new
                # mail, FETCH when flags change elsewhere, EXPUNGE on delete).
                # We resync fully, so there is no need to parse which it was.
                if line.startswith(b"*"):
                    reason = "push"
                    break

            if stdin_open and sys.stdin in readable:
                command = sys.stdin.readline()
                if command == "":
                    return "stdin-closed"
                if command.strip() == "refresh":
                    reason = "manual"
                    break
        else:
            reason = "stopped"
    finally:
        # On shutdown, skip the polite DONE handshake: the socket is about to
        # close anyway and a dead connection could block us for the timeout.
        if _running:
            stop_idle(imap, tag)

    return reason


def run_session(max_messages, last_signature):
    """One connected session. Returns the last signature emitted."""
    imap, address, user_index = gmail_imap.connect()
    stdin_open = not sys.stdin.closed

    try:
        payload = gmail_imap.fetch_state(imap, address, user_index, max_messages)
        if signature(payload) != last_signature:
            if not emit(payload):
                return last_signature, False
            last_signature = signature(payload)

        while _running:
            reason = idle_once(imap, stdin_open)
            if reason in ("stdin-closed", "stopped"):
                return last_signature, False

            payload = gmail_imap.fetch_state(imap, address, user_index, max_messages)
            current = signature(payload)
            # A manual refresh always reports back, so the UI can stop showing
            # a spinner even when nothing changed.
            if current != last_signature or reason == "manual":
                if not emit(payload):
                    return last_signature, False
                last_signature = current

        return last_signature, False
    finally:
        # A graceful LOGOUT waits for a tagged reply. On shutdown we skipped
        # the IDLE DONE handshake, so the server is still idling and that wait
        # would burn the whole socket timeout; drop the socket instead.
        try:
            if _running:
                imap.logout()
            else:
                imap.shutdown()
        except Exception:
            pass


def main():
    max_messages = 10
    if len(sys.argv) > 1:
        try:
            max_messages = max(0, min(50, int(sys.argv[1])))
        except ValueError:
            pass

    backoff = BACKOFF_START
    failures = 0
    last_signature = None

    while _running:
        try:
            last_signature, keep_going = run_session(max_messages, last_signature)
            if not keep_going:
                return 0
            backoff = BACKOFF_START
            failures = 0
        except gmail_imap.SetupNeeded as exc:
            payload = gmail_imap.error_payload(exc, needs_setup=True)
            if signature(payload) != last_signature:
                if not emit(payload):
                    return 0
                last_signature = signature(payload)
            # Wait for the user to run omarchy-gmail-setup.
            for _ in range(30):
                if not _running:
                    return 0
                time.sleep(1)
            continue
        except imaplib.IMAP4.error as exc:
            text, needs_setup = gmail_imap.describe_imap_error(exc)
            failures += 1
            if needs_setup or failures >= FAILURES_BEFORE_REPORTING:
                payload = gmail_imap.error_payload(text, needs_setup=needs_setup)
                if signature(payload) != last_signature:
                    if not emit(payload):
                        return 0
                    last_signature = signature(payload)
        except (OSError, ConnectionError, RuntimeError) as exc:
            failures += 1
            if failures >= FAILURES_BEFORE_REPORTING:
                detail = getattr(exc, "strerror", None) or str(exc)
                payload = gmail_imap.error_payload(detail)
                if signature(payload) != last_signature:
                    if not emit(payload):
                        return 0
                    last_signature = signature(payload)

        # Reconnect with backoff, staying responsive to SIGTERM.
        slept = 0
        while slept < backoff and _running:
            time.sleep(0.5)
            slept += 0.5
        backoff = min(BACKOFF_MAX, backoff * 2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
