"""A minimal web front end for P-agent: the CLI in a browser tab.

    python3 web/server.py [--port 8765] [--host 127.0.0.1]     (Linux / WSL)
    then open http://localhost:8765

It runs the normal CLI (`sh run.sh main.metta`) inside a pseudo-terminal, so
the agent behaves exactly as in a terminal: colours, typed input echoed,
approvals [y/N], ask-user questions, and "c + Enter" to cancel a goal.
The page shows two live views:

    terminal        everything the agent prints, as in the CLI
    backend events  each line the agent appends to the audit log
                    (PAGENT_AUDIT, default data/audit.jsonl): tool calls,
                    approvals, denials, model switches, empty replies

Python standard library only. One agent process, shared by every open tab.
It listens on localhost only and refuses cross-site requests: the agent
can run shell commands, so it must not be reachable from other machines or
driven by other web pages.
"""
import argparse
import codecs
import fcntl
import json
import os
import pty
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WEB = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(WEB)
AUDIT = os.path.join(PROJECT, os.environ.get("PAGENT_AUDIT", "data/audit.jsonl"))
HISTORY_LIMIT = 4000          # stream entries kept for tabs that (re)connect


class Stream:
    """Everything sent to the page, numbered: ("out", text) | ("audit", event) | ("state", info)."""

    def __init__(self):
        self.items = []           # (seq, kind, payload)
        self.seq = 0
        self.cond = threading.Condition()

    def add(self, kind, payload):
        with self.cond:
            self.seq += 1
            self.items.append((self.seq, kind, payload))
            del self.items[:-HISTORY_LIMIT]
            self.cond.notify_all()

    def since(self, seq, timeout):
        with self.cond:
            if not self.items or self.items[-1][0] <= seq:
                self.cond.wait(timeout)
            return [i for i in self.items if i[0] > seq]


STREAM = Stream()


class Agent:
    """The CLI process, attached to a pseudo-terminal."""

    def __init__(self):
        self.proc = None
        self.master = None
        self.lock = threading.Lock()

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        with self.lock:
            if self.running():
                return
            master, slave = os.openpty()
            # 120 columns: the CLI's lines are written for a wide terminal
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            env = dict(os.environ, TERM="xterm-256color")
            self.proc = subprocess.Popen(["sh", "run.sh", "main.metta"], cwd=PROJECT,
                                         stdin=slave, stdout=slave, stderr=slave,
                                         env=env, start_new_session=True, close_fds=True)
            os.close(slave)
            self.master = master
            STREAM.add("state", {"running": True})
            threading.Thread(target=self._read, args=(self.proc, master), daemon=True).start()

    def _read(self, proc, master):
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        while True:
            try:
                data = os.read(master, 4096)
            except OSError:            # EIO: the process closed the terminal
                data = b""
            if not data:
                break
            STREAM.add("out", decoder.decode(data))
        code = proc.wait()
        try:
            os.close(master)
        except OSError:
            pass
        STREAM.add("out", f"\r\n[agent exited with code {code} — press Restart to start a new session]\r\n")
        if proc is self.proc:          # not when Restart already started a new one
            STREAM.add("state", {"running": False})

    def send(self, text):
        if not self.running():
            return False
        # a line typed at the terminal: the pty echoes it and turns \r into \n
        os.write(self.master, (str(text).replace("\n", " ") + "\r").encode("utf-8"))
        return True

    def stop(self):
        with self.lock:
            if self.running():
                try:
                    os.killpg(self.proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    self.proc.wait(5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)


AGENT = Agent()


def tail_audit():
    """Follow the audit log: only events written after the server started."""
    pos = os.path.getsize(AUDIT) if os.path.exists(AUDIT) else 0
    rest = ""
    while True:
        time.sleep(0.4)
        try:
            size = os.path.getsize(AUDIT)
        except OSError:
            continue
        if size < pos:                 # the file was replaced: start again from its top
            pos, rest = 0, ""
        if size == pos:
            continue
        with open(AUDIT, encoding="utf-8", errors="replace") as f:
            f.seek(pos)
            chunk = f.read()
            pos = f.tell()
        lines = (rest + chunk).split("\n")
        rest = lines.pop()             # a line still being written
        for line in lines:
            try:
                STREAM.add("audit", json.loads(line))
            except ValueError:
                pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):     # keep the server's own terminal quiet
        pass

    # ---- safety: local only, same origin only ----
    def _local_host(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        return host in ("localhost", "127.0.0.1", "::1")

    def _same_origin(self):
        origin = self.headers.get("Origin")
        return origin is None or origin == f"http://{self.headers.get('Host')}"

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._local_host():
            return self._send(403, {"error": "local access only"})
        url = urlparse(self.path)
        if url.path == "/":
            with open(os.path.join(WEB, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if url.path == "/events":
            return self._events(url)
        if url.path == "/status":
            return self._send(200, {"running": AGENT.running()})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not (self._local_host() and self._same_origin()):
            return self._send(403, {"error": "cross-site request refused"})
        length = min(int(self.headers.get("Content-Length") or 0), 100_000)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._send(400, {"error": "bad JSON"})
        path = urlparse(self.path).path
        if path == "/input":
            return self._send(200, {"sent": AGENT.send(body.get("text", ""))})
        if path == "/cancel":          # the CLI's own cancel: c + Enter
            return self._send(200, {"sent": AGENT.send("c")})
        if path == "/restart":
            AGENT.stop()
            AGENT.start()
            return self._send(200, {"running": AGENT.running()})
        self._send(404, {"error": "not found"})

    def _events(self, url):
        """Server-sent events: the history first, then live entries."""
        try:
            seq = int(self.headers.get("Last-Event-ID") or parse_qs(url.query).get("since", ["0"])[0])
        except ValueError:
            seq = 0
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            self.wfile.write(f"event: state\ndata: {json.dumps({'running': AGENT.running()})}\n\n".encode())
            while True:
                items = STREAM.since(seq, timeout=15)
                if not items:
                    self.wfile.write(b": keep-alive\n\n")
                for s, kind, payload in items:
                    self.wfile.write(f"id: {s}\nevent: {kind}\ndata: {json.dumps(payload)}\n\n".encode())
                    seq = s
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()
    threading.Thread(target=tail_audit, daemon=True).start()
    AGENT.start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"P-agent web UI: http://localhost:{args.port}   (Ctrl+C stops the server and the agent)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        AGENT.stop()


if __name__ == "__main__":
    sys.exit(main())
