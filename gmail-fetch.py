#!/usr/bin/env python3
"""One-shot Gmail unread state as JSON on stdout.

Kept for `omarchy-gmail-setup --status` and manual debugging; the bar widget
itself uses gmail-watch.py, which holds an IMAP IDLE connection. Always prints
valid JSON and exits 0, so callers only inspect the `ok` field.
"""

import imaplib
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import gmail_imap


def main():
    max_messages = 10
    if len(sys.argv) > 1:
        try:
            max_messages = max(0, min(50, int(sys.argv[1])))
        except ValueError:
            pass

    try:
        payload = gmail_imap.collect(max_messages)
    except gmail_imap.SetupNeeded as exc:
        payload = gmail_imap.error_payload(exc, needs_setup=True)
    except imaplib.IMAP4.error as exc:
        text, needs_setup = gmail_imap.describe_imap_error(exc)
        payload = gmail_imap.error_payload(text, needs_setup=needs_setup)
    except OSError as exc:
        payload = gmail_imap.error_payload(exc.strerror or exc)
    except Exception as exc:
        payload = gmail_imap.error_payload(exc)

    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
