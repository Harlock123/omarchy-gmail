"""Shared Gmail/IMAP logic for the Omarchy bar widget.

Used by gmail-fetch.py (one-shot) and gmail-watch.py (long-running IDLE
watcher). Connection handling is split from state fetching so the watcher can
reuse a single authenticated connection across many resyncs.
"""

import email
import email.policy
import email.utils
import html as htmllib
import imaplib
import json
import os
import re
import subprocess

IMAP_HOST = "imap.gmail.com"
IMAP_PORT = 993
SOCKET_TIMEOUT = 20
BODY_PREFIX_BYTES = 16384

CONFIG_PATH = os.path.expanduser("~/.config/omarchy/gmail.json")
PASSWORD_FILE = os.path.expanduser("~/.config/omarchy/gmail-password")

TAG_RE = re.compile(r"<[^>]+>")
DROP_BLOCK_RE = re.compile(r"(?is)<(script|style|head)\b.*?</\1>")
WS_RE = re.compile(r"\s+")
QUOTE_RE = re.compile(r"(?m)^\s*>.*$")
THRID_RE = re.compile(rb"X-GM-THRID\s+(\d+)")
UID_RE = re.compile(rb"UID\s+(\d+)")


class SetupNeeded(Exception):
    """Raised when the account is not configured or the credential is gone."""


def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError:
        raise SetupNeeded("Gmail account not configured")
    except (OSError, ValueError) as exc:
        raise SetupNeeded("Could not read %s: %s" % (CONFIG_PATH, exc))

    address = str(config.get("email") or "").strip()
    if not address:
        raise SetupNeeded("no email address in %s" % CONFIG_PATH)
    try:
        user_index = max(0, int(config.get("userIndex", 0)))
    except (TypeError, ValueError):
        user_index = 0
    return address, user_index


def load_password(address):
    """Keyring first; fall back to a 0600 file for headless/locked sessions."""
    try:
        result = subprocess.run(
            ["secret-tool", "lookup", "service", "omarchy-gmail", "account", address],
            capture_output=True,
            timeout=10,
        )
        if result.returncode == 0:
            secret = result.stdout.decode("utf-8", "replace").strip()
            if secret:
                return secret
    except (OSError, subprocess.SubprocessError):
        pass

    if os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, "r", encoding="utf-8") as handle:
            secret = handle.read().strip()
        if secret:
            return secret

    raise SetupNeeded("no app password found in the keyring for %s" % address)


def connect():
    """Authenticate and select INBOX. Returns (imap, address, user_index)."""
    address, user_index = load_config()
    password = load_password(address)
    imap = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, timeout=SOCKET_TIMEOUT)
    imap.login(address, password)
    imap.select("INBOX", readonly=True)
    return imap, address, user_index


def decode_header_value(value):
    if value is None:
        return ""
    return WS_RE.sub(" ", str(value)).strip()


def html_to_text(raw):
    return TAG_RE.sub(" ", DROP_BLOCK_RE.sub(" ", raw))


def part_text(part):
    try:
        payload = part.get_payload(decode=True)
    except Exception:
        return None
    if not payload:
        return None
    charset = part.get_content_charset() or "utf-8"
    try:
        return payload.decode(charset, errors="replace")
    except (LookupError, UnicodeDecodeError):
        return payload.decode("utf-8", errors="replace")


def extract_snippet(message, limit=220):
    """Best-effort preview: prefer text/plain, fall back to stripped HTML."""
    plain = None
    markup = None

    parts = message.walk() if message.is_multipart() else [message]
    for part in parts:
        if part.is_multipart():
            continue
        disposition = str(part.get("Content-Disposition") or "").lower()
        if "attachment" in disposition:
            continue
        content_type = part.get_content_type()
        if content_type not in ("text/plain", "text/html"):
            continue
        text = part_text(part)
        if not text:
            continue
        if content_type == "text/plain" and plain is None:
            plain = text
        elif content_type == "text/html" and markup is None:
            markup = text
        if plain:
            break

    source = plain if plain else (html_to_text(markup) if markup else "")
    if not source:
        return ""

    source = QUOTE_RE.sub(" ", source)
    source = htmllib.unescape(source)
    source = WS_RE.sub(" ", source).strip()
    if len(source) > limit:
        source = source[: limit - 1].rstrip() + "…"
    return source


def message_timestamp(message):
    raw = message.get("Date")
    if not raw:
        return 0
    try:
        parsed = email.utils.parsedate_to_datetime(str(raw))
    except (TypeError, ValueError):
        return 0
    if parsed is None:
        return 0
    try:
        return int(parsed.timestamp())
    except (OSError, OverflowError, ValueError):
        return 0


def fetch_thread_ids(imap, uids):
    """Map uid -> X-GM-THRID. The hex form of THRID is the web-UI thread id."""
    mapping = {}
    if not uids:
        return mapping
    status, data = imap.uid("FETCH", ",".join(uids), "(X-GM-THRID)")
    if status != "OK":
        return mapping
    for entry in data:
        line = entry[0] if isinstance(entry, tuple) else entry
        if not isinstance(line, bytes):
            continue
        uid_match = UID_RE.search(line)
        thrid_match = THRID_RE.search(line)
        if uid_match and thrid_match:
            mapping[uid_match.group(1).decode()] = int(thrid_match.group(1))
    return mapping


def fetch_message(imap, uid):
    status, data = imap.uid("FETCH", uid, "(BODY.PEEK[]<0.%d>)" % BODY_PREFIX_BYTES)
    if status != "OK":
        return None
    for entry in data:
        if isinstance(entry, tuple) and len(entry) >= 2 and isinstance(entry[1], bytes):
            return email.message_from_bytes(entry[1], policy=email.policy.default)
    return None


def fetch_state(imap, address, user_index, max_messages):
    """Read current unread state over an already-authenticated connection."""
    status, data = imap.uid("SEARCH", None, "UNSEEN")
    if status != "OK":
        raise RuntimeError("IMAP search failed")

    uids = [uid.decode() for uid in (data[0] or b"").split()]
    unread_total = len(uids)

    recent = uids[-max_messages:] if max_messages > 0 else []
    recent.reverse()

    thread_ids = fetch_thread_ids(imap, recent)

    messages = []
    for uid in recent:
        parsed = fetch_message(imap, uid)
        if parsed is None:
            continue
        sender_name, sender_email = email.utils.parseaddr(
            decode_header_value(parsed.get("From"))
        )
        thrid = thread_ids.get(uid)
        url = (
            "https://mail.google.com/mail/u/%d/#inbox/%x" % (user_index, thrid)
            if thrid
            else "https://mail.google.com/mail/u/%d/#inbox" % user_index
        )
        messages.append(
            {
                "uid": uid,
                "from": sender_name or sender_email or "(unknown sender)",
                "fromEmail": sender_email,
                "subject": decode_header_value(parsed.get("Subject")) or "(no subject)",
                "snippet": extract_snippet(parsed),
                "timestamp": message_timestamp(parsed),
                "url": url,
            }
        )

    return {
        "ok": True,
        "error": "",
        "needsSetup": False,
        "account": address,
        "unread": unread_total,
        "shown": len(messages),
        "inboxUrl": "https://mail.google.com/mail/u/%d/#inbox" % user_index,
        "messages": messages,
    }


def error_payload(message, needs_setup=False):
    return {
        "ok": False,
        "error": str(message),
        "needsSetup": needs_setup,
        "account": "",
        "unread": 0,
        "shown": 0,
        "inboxUrl": "https://mail.google.com/mail/u/0/#inbox",
        "messages": [],
    }


def describe_imap_error(exc):
    """Return (text, needs_setup) for an imaplib error."""
    detail = exc.args[0] if exc.args else exc
    if isinstance(detail, bytes):
        detail = detail.decode("utf-8", "replace")
    text = str(detail)
    if "AUTHENTICATIONFAILED" in text.upper():
        return "Gmail rejected the login", True
    return text, False


def collect(max_messages):
    """One-shot: connect, read state, disconnect."""
    imap, address, user_index = connect()
    try:
        return fetch_state(imap, address, user_index, max_messages)
    finally:
        try:
            imap.logout()
        except Exception:
            pass
