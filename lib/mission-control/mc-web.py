#!/usr/bin/env python3
"""mc-web: the mission-control board as a local web page.

Serves mc-web.html on 127.0.0.1 and two JSON endpoints:

  GET  /api/board   state.json, the queued inbox lines, the switch flags and the loop heartbeat
  POST /api/action  {"verb", "ticket", "note"} -> runs `mc <verb> <TICKET>[: note]`

Every action goes through the `mc` shell function, so the inbox line, the not-on-board
warning and the work-log entry are exactly what typing the verb would produce. The page
never writes state.json; the loop stays its only writer.

Both endpoints need the per-run token baked into the page, and every request must name
this server in its Host header. That keeps other sites in the browser (and DNS rebinding)
from reading the board or queueing a verb.

  MC_WEB_PORT=7317 ./mc-web.py      # then open the URL it prints
"""

import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import time
import unicodedata
from urllib.parse import urlsplit

LIB = os.path.dirname(os.path.realpath(__file__))
MC_HOME = os.environ.get("MC_HOME", os.path.expanduser("~/.claude/mission-control"))


def _path(env, name):
    return os.environ.get(env, os.path.join(MC_HOME, name))


STATE = _path("MC_STATE", "state.json")
INBOX = _path("MC_INBOX", "mc-inbox")
HEARTBEAT = _path("MC_HEARTBEAT_FILE", ".loop-heartbeat")
NEXT_WAKE = _path("MC_NEXT_WAKE_FILE", ".loop-next-wake")
DASH_NEXT_WAKE = _path("MC_DASH_NEXT_WAKE_FILE", ".dash-next-wake")
FLAGS = {
    "paused": _path("MC_PAUSE_FILE", "PAUSED"),
    "coder": _path("MC_CODER_FILE", "CODER_SPAWN_LIVE"),
    "gate1": _path("MC_GATE1_FILE", "GATE1_AUTO"),
    "address": _path("MC_ADDRESS_FILE", "KICKBACK_AUTO"),
    "adopt_off": _path("MC_ADOPT_OFF_FILE", "ADOPT_OFF"),
}
MC_SCRIPT = os.environ.get("MC_SCRIPT", os.path.join(LIB, "mc"))
PAGE = os.path.join(LIB, "mc-web.html")
PORT = int(os.environ.get("MC_WEB_PORT", "7317"))
BROWSE_URL = os.environ.get("MC_TRACKER_BROWSE_URL", "")
STALE_SECS = int(os.environ.get("MC_LOOP_STALE_SECS", "1500"))

TOKEN = os.environ.get("MC_WEB_TOKEN") or secrets.token_urlsafe(24)

QUEUED_VERBS = {"approve", "ready", "merge", "qa", "changes", "plan", "hold", "unblock", "note"}
NOTE_REQUIRED = {"changes", "hold", "note"}
NOTE_FORBIDDEN = {"approve", "ready", "merge", "qa", "plan", "unblock"}
KEY_RE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]+$")
NOTE_MAX = 500


def read_state():
    # Why: the loop rewrites state.json in place, so a read can land mid-write.
    for _ in range(5):
        try:
            with open(STATE) as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.08)
    return None


def read_digits(path):
    try:
        with open(path) as f:
            raw = f.read()
    except OSError:
        return None, ""
    digits = re.match(r"\s*(\d+)", raw)
    return (int(digits.group(1)) if digits else None), raw[digits.end():].strip() if digits else ""


def inbox_lines():
    try:
        with open(INBOX) as f:
            return [l.rstrip("\n") for l in f if l.strip() and not l.lstrip().startswith("#")]
    except OSError:
        return []


def board():
    hb, tag = read_digits(HEARTBEAT)
    loop = "dash" if tag == "dash" else "main"
    nw, _ = read_digits(DASH_NEXT_WAKE if loop == "dash" else NEXT_WAKE)
    flags = {name: os.path.exists(p) for name, p in FLAGS.items()}
    drain = False
    if flags["paused"]:
        try:
            with open(FLAGS["paused"]) as f:
                drain = "mode=drain" in f.read()
        except OSError:
            pass
    stale = STALE_SECS
    if hb and nw and nw > hb:
        stale = max(stale, nw - hb + 900)
    return {
        "state": read_state(),
        "inbox": inbox_lines(),
        "flags": dict(flags, drain=drain),
        "loop": {"heartbeat": hb, "kind": loop, "next_wake": nw, "stale_secs": stale},
        "browse_url": BROWSE_URL,
        "now": int(time.time()),
    }


def on_board(state, key):
    return any((t.get("ticket") or "").upper() == key for t in (state or {}).get("tickets", []))


def validate(body):
    verb = str(body.get("verb", "")).strip()
    key = str(body.get("ticket", "")).strip().upper()
    note = body.get("note")
    note = "" if note is None else str(note).strip()
    if verb not in QUEUED_VERBS:
        return None, "unknown verb"
    if not KEY_RE.match(key):
        return None, "bad ticket key"
    if not on_board(read_state(), key):
        return None, key + " is not on the board"
    # Why: the inbox is one command per line, so any line break (U+2028 and NEL included) would
    # queue a second verb.
    if any(unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp") for c in note):
        return None, "note must be one line"
    if len(note) > NOTE_MAX:
        return None, "note is over %d characters" % NOTE_MAX
    if verb in NOTE_REQUIRED and not note:
        return None, verb + " needs a note"
    if verb in NOTE_FORBIDDEN and note:
        return None, verb + " takes no note"
    return [verb, key + ": " + note if note else key], None


def run_mc(args):
    proc = subprocess.run(
        ["bash", "-c", 'pbcopy() { cat >/dev/null; }; . "$0"; mc "$@"', MC_SCRIPT] + args,
        capture_output=True, text=True, timeout=20,
        env=dict(os.environ, MC_INBOX=INBOX, MC_STATE=STATE),
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "mc-web"

    def log_message(self, fmt, *args):
        if os.environ.get("MC_WEB_QUIET"):
            return
        sys.stderr.write("mc-web: " + (fmt % args) + "\n")

    def _host_ok(self):
        return self.headers.get("Host", "") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def _token_ok(self):
        return secrets.compare_digest(self.headers.get("X-MC-Token", ""), TOKEN)

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        # Why: a framed copy of the page carries its own token, so framing would allow clickjacking.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "frame-ancestors 'none'; default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "bad host"})
        path = urlsplit(self.path).path
        if path in ("/", "/index.html"):
            with open(PAGE, "rb") as f:
                page = f.read().replace(b"__MC_TOKEN__", TOKEN.encode())
            return self._send(200, page, "text/html; charset=utf-8")
        if path == "/api/board":
            if not self._token_ok():
                return self._send(403, {"error": "bad token"})
            return self._send(200, board())
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok():
            return self._send(403, {"error": "bad host"})
        if self.path != "/api/action":
            return self._send(404, {"error": "not found"})
        if not self._token_ok():
            return self._send(403, {"error": "bad token"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 4096:
                raise ValueError
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "bad json"})
        args, err = validate(body)
        if err:
            return self._send(422, {"error": err})
        code, out = run_mc(args)
        self._send(200 if code == 0 else 500, {"ok": code == 0, "output": out, "line": " ".join(args)})


def main():
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("mc-web: http://127.0.0.1:%d/  (Ctrl-C to stop)" % PORT, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
