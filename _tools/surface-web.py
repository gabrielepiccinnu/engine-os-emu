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
"""
import http.server
import os
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
        elif self.path == "/status":
            ok = pipe.alive() or pipe.open()
            self._reply(200, '{"connected": %s, "sent": %d, "error": %s}'
                        % ("true" if ok else "false", pipe.sent,
                           '"%s"' % pipe.error.replace('"', "'")),
                        "application/json")
        else:
            self._reply(404, "not found")

    def do_POST(self):
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
    src = os.path.join(VM, "id_vm")
    if not os.path.exists(src):
        sys.exit("no %s: build or export the VM first" % src)
    with open(src, "rb") as f, open(KEY, "wb") as g:
        g.write(f.read())
    os.chmod(KEY, 0o600)

    if pipe.open():
        print("guest: connected to the Control Surface inject port")
    else:
        print("guest: not reachable yet (%s), will retry on the first message" % pipe.error)

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
        if pipe.proc:
            pipe.proc.terminate()


if __name__ == "__main__":
    main()
