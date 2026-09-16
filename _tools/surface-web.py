#!/usr/bin/env python3
"""Serves the Mixstream Pro control surface as a web page, and forwards
what it sends into the guest's virtual surface.

    python3 _tools/surface-web.py            # http://127.0.0.1:8808, opens the browser
    HOST=0.0.0.0 python3 _tools/surface-web.py   # reachable from a phone on the LAN

The page (surface.html, next to this file) POSTs MIDI bytes as hex to /midi.
One ssh session is kept open to the guest with `cat` writing to the inject
device of the Control Surface card, and every message goes down that pipe as
raw bytes. No process is spawned per message, on either side: a knob turn is a
few hundred CCs a second and each `amidi` would cost tens of milliseconds
under emulation. The ssh key and port are the ones every other tool here uses.

The other direction is /events: a second ssh session reads what Engine writes
to the surface from /proc/asound/Surface/monitor, the bytes are parsed into
notes and CCs, and every change is pushed to the page as a server-sent event.
That is how the LEDs and the VU meters light up: Engine drives them exactly as
it would the real buttons.

BOARD=1 points all of it at the Tinker Board instead of the QEMU guest: the
same module is loaded there, so the same bytes go to the same device. In that
mode the page also carries the board's display with touch, served by the
remote desktop code in _tools/board/remote-web.py (/stream, /touch).
"""
import http.server
import importlib.util
import json
import os
import queue
import subprocess
import sys
import threading
import time
import webbrowser

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VM = os.path.join(BASE, "_vm")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8808"))
KEY = "/tmp/id_vm_web"
BOARD = bool(os.environ.get("BOARD"))

remote = None
if BOARD:
    spec = importlib.util.spec_from_file_location("remote_web", os.path.join(BASE, "_tools", "board", "remote-web.py"))
    remote = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(remote)
    SSH = remote.SSH
else:
    SSH = ["ssh", "-p", "2222", "-i", KEY, "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
           "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR", "root@127.0.0.1"]

# The card index is not fixed, the Surface card comes after the audio one:
# resolve it in the guest from the /proc/asound symlink, then keep writing.
GUEST_CMD = ("n=$(readlink /proc/asound/Surface | tr -dc 0-9); "
             "[ -n \"$n\" ] || { echo 'no Control Surface card' >&2; exit 1; }; "
             "exec cat > /dev/snd/midiC${n}D1")


class Pipe:
    """The ssh session carrying the bytes. Reopened when it drops."""

    def __init__(self):
        self.proc = None
        self.lock = threading.Lock()
        self.sent = 0
        self.error = ""

    def open(self):
        if self.proc and self.proc.poll() is None:
            return True
        try:
            self.proc = subprocess.Popen(SSH + [GUEST_CMD], stdin=subprocess.PIPE,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            time.sleep(0.3)
            if self.proc.poll() is not None:
                self.error = self.proc.stderr.read().decode(errors="replace").strip() or "ssh exited"
                return False
            self.error = ""
            return True
        except OSError as e:
            self.error = str(e)
            return False

    def send(self, data: bytes) -> bool:
        with self.lock:
            if not self.open():
                return False
            try:
                self.proc.stdin.write(data)
                self.proc.stdin.flush()
                self.sent += len(data)
                return True
            except (BrokenPipeError, OSError) as e:
                self.error = str(e)
                self.proc = None
                return False

    def alive(self):
        return self.proc is not None and self.proc.poll() is None


pipe = Pipe()


class Monitor(threading.Thread):
    """Reads Engine's output to the surface and keeps the LED and CC state."""

    def __init__(self):
        super().__init__(daemon=True)
        self.state = {}           # "n:ch:note" -> velocity, "c:ch:cc" -> value
        self.lock = threading.Lock()
        self.listeners = []       # queues of connected /events clients
        self.proc = None

    def run(self):
        while True:
            try:
                self.proc = subprocess.Popen(SSH + ["cat /proc/asound/Surface/monitor"],
                                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                self.parse(self.proc.stdout)
            except OSError:
                pass
            time.sleep(2)         # the guest is down, or Engine restarted: try again

    def parse(self, stream):
        status, data, need = 0, [], 0
        while True:
            chunk = stream.read1(256) if hasattr(stream, "read1") else stream.read(1)
            if not chunk:
                return
            for b in chunk:
                if b == 0xF0:                     # SysEx: skip to F7
                    status = 0xF0; continue
                if status == 0xF0:
                    if b == 0xF7: status = 0
                    continue
                if b >= 0xF8:                     # realtime, ignore
                    continue
                if b & 0x80:
                    status, data = b, []
                    need = 1 if (b & 0xF0) in (0xC0, 0xD0) else 2
                    continue
                if not status:
                    continue
                data.append(b)
                if len(data) == need:
                    self.message(status, data)
                    data = []                     # running status keeps `status`

    def message(self, status, data):
        kind, ch = status & 0xF0, status & 0x0F
        if kind in (0x90, 0x80):
            key, val = "n:%d:%d" % (ch, data[0]), (data[1] if kind == 0x90 else 0)
        elif kind == 0xB0:
            key, val = "c:%d:%d" % (ch, data[0]), data[1]
        else:
            return
        with self.lock:
            if self.state.get(key) == val:
                return
            self.state[key] = val
            ev = json.dumps({"k": key, "v": val})
            for q in self.listeners:
                try: q.put_nowait(ev)
                except queue.Full: pass

    def subscribe(self):
        q = queue.Queue(maxsize=2000)
        with self.lock:
            snapshot = json.dumps(self.state)
            self.listeners.append(q)
        return q, snapshot

    def unsubscribe(self, q):
        with self.lock:
            if q in self.listeners:
                self.listeners.remove(q)


monitor = Monitor()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet: a knob turn is hundreds of requests
        pass

    def _reply(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(BASE, "_tools", "surface.html"), "rb") as f:
                self._reply(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            q, snapshot = monitor.subscribe()
            try:
                self.wfile.write(("event: state\ndata: %s\n\n" % snapshot).encode()); self.wfile.flush()
                while True:
                    try:
                        ev = q.get(timeout=15)
                        self.wfile.write(("data: %s\n\n" % ev).encode())
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                monitor.unsubscribe(q)
        elif self.path == "/status":
            ok = pipe.alive() or pipe.open()
            self._reply(200, '{"connected": %s, "sent": %d, "error": %s, "target": "%s"}'
                        % ("true" if ok else "false", pipe.sent,
                           '"%s"' % pipe.error.replace('"', "'"), "board" if BOARD else "qemu"),
                        "application/json")
        elif remote and (self.path == "/config" or self.path.startswith("/stream")):
            remote.Handler.do_GET(self)          # the board's display: same handlers, same server
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if remote and self.path == "/touch":
            return remote.Handler.do_POST(self)
        if self.path != "/midi":
            return self._reply(404, "not found")
        n = int(self.headers.get("Content-Length", "0"))
        hexstr = self.rfile.read(n).decode(errors="replace")
        try:
            data = bytes.fromhex("".join(hexstr.split()))
        except ValueError:
            return self._reply(400, "bad hex")
        if not data:
            return self._reply(400, "empty")
        if pipe.send(data):
            self._reply(200, "ok")
        else:
            self._reply(503, pipe.error or "not connected")


def main():
    if not BOARD:
        src = os.path.join(VM, "id_vm")
        if not os.path.exists(src):
            sys.exit("no %s: build or export the VM first" % src)
        with open(src, "rb") as f, open(KEY, "wb") as g:
            g.write(f.read())
        os.chmod(KEY, 0o600)
    else:
        remote.frames.start()
        print("target: the Tinker Board, with its display on the page")

    if pipe.open():
        print("guest: connected to the Control Surface inject port")
    else:
        print("guest: not reachable yet (%s), will retry on the first message" % pipe.error)
    monitor.start()

    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    url = "http://%s:%d/" % ("127.0.0.1" if HOST == "0.0.0.0" else HOST, PORT)
    print("surface: %s   (Ctrl-C to stop)" % url)
    if HOST in ("127.0.0.1", "localhost") and not os.environ.get("NO_BROWSER"):
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for p in (pipe.proc, monitor.proc):
            if p:
                p.terminate()


if __name__ == "__main__":
    main()
