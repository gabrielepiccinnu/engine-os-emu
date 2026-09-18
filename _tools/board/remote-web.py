#!/usr/bin/env python3
"""The Tinker Board's display in a browser, with touch: a remote desktop for
Engine OS on the board.

    python3 _tools/board/remote-web.py        # http://127.0.0.1:8811/

The picture is az01-mirror.sh's MJPEG stream. ffmpeg serves one client at a
time, so this server is that client: it reads the stream once and hands the
latest frame to every page on /stream, as many as are open. Touch goes the
other way: a press, drag or release on the
picture is scaled to the board's screen and written, as the "d x y", "m x y"
and "u" lines uinput-touch.c understands, into /tmp/tapfifo on the board
through one ssh session that stays open. Absolute coordinates, so there is
no pointer to chase: a finger lands where the picture was touched. This is
what the device's own touchscreen does, and Engine cannot tell the difference.

BOARD_HOST, BOARD_IF and MIRROR override the addresses.
"""
import http.server
import os
import subprocess
import threading
import time
import urllib.request
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8811"))
BOARD_IF = os.environ.get("BOARD_IF", "en0")
BOARD = os.environ.get("BOARD_HOST", "fe80::8ad7:f6ff:fec2:c5c1%" + BOARD_IF)
MIRROR = os.environ.get("MIRROR", "http://169.254.41.200:8090/")
SSH = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
       "root@" + BOARD]


class Fifo:
    """One ssh session holding the fifo open as its writer."""

    def __init__(self):
        self.proc, self.lock, self.error, self.sent = None, threading.Lock(), "", 0

    def open(self):
        if self.proc and self.proc.poll() is None:
            return True
        try:
            self.proc = subprocess.Popen(SSH + ["exec cat > /tmp/tapfifo"], stdin=subprocess.PIPE,
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

    def send(self, text):
        with self.lock:
            if not self.open():
                return False
            try:
                self.proc.stdin.write(text.encode())
                self.proc.stdin.flush()
                self.sent += 1
                return True
            except (BrokenPipeError, OSError) as e:
                self.error, self.proc = str(e), None
                return False


fifo = Fifo()


class Frames(threading.Thread):
    """The one connection to the board's stream; keeps the newest JPEG."""

    def __init__(self):
        super().__init__(daemon=True)
        self.jpeg, self.seq, self.cond, self.error = b"", 0, threading.Condition(), "not started"

    def run(self):
        while True:
            try:
                with urllib.request.urlopen(MIRROR, timeout=10) as r:
                    self.error = ""
                    buf = b""
                    while True:
                        # read1: whatever has arrived, not a full 64 KB, or a
                        # frame would wait for the next three to fill the buffer
                        chunk = r.read1(65536)
                        if not chunk:
                            break
                        buf += chunk
                        # ffmpeg's mpjpeg: a boundary, headers, then the JPEG; SOI/EOI is
                        # all that is needed to cut frames out of it
                        while True:
                            i = buf.find(b"\xff\xd8")
                            if i < 0:
                                buf = buf[-2:]; break
                            j = buf.find(b"\xff\xd9", i + 2)
                            if j < 0:
                                buf = buf[i:]; break
                            with self.cond:
                                self.jpeg, self.seq = buf[i:j + 2], self.seq + 1
                                self.cond.notify_all()
                            buf = buf[j + 2:]
            except Exception as e:
                self.error = str(e)
            time.sleep(1.5)                       # the streamer restarts between clients

    def wait(self, seen, timeout=2.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != seen, timeout)
            return self.jpeg, self.seq


frames = Frames()


class Stats(threading.Thread):
    """The board's temperature, clock and CPU use: one ssh session in which
    the board prints a line every few seconds, so that the page can show them
    without a new ssh per look. CPU use is /proc/stat's first line differenced
    between two prints, as top does."""

    LOOP = ("while :; do echo $(cat /sys/class/thermal/thermal_zone0/temp) "
            "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) "
            "$(cut -d' ' -f1 /proc/loadavg) $(head -n1 /proc/stat); sleep 3; done")

    def __init__(self):
        super().__init__(daemon=True)
        self.temp, self.mhz, self.load, self.cpu, self.error = 0, 0, 0.0, 0, "not started"
        self.busy_idle = None

    def run(self):
        while True:
            try:
                proc = subprocess.Popen(SSH + [self.LOOP], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        stdin=subprocess.DEVNULL, text=True)
                for line in proc.stdout:
                    f = line.split()
                    if len(f) < 8 or f[3] != "cpu":
                        continue
                    self.temp, self.mhz, self.load = int(f[0]) // 1000, int(f[1]) // 1000, float(f[2])
                    t = [int(x) for x in f[4:]]
                    idle, total = t[3] + t[4], sum(t)
                    if self.busy_idle:
                        di, dt = idle - self.busy_idle[0], total - self.busy_idle[1]
                        self.cpu = int(round(100 * (1 - di / dt))) if dt > 0 else 0
                    self.busy_idle, self.error = (idle, total), ""
                proc.wait()
                self.error = "ssh exited"
            except Exception as e:
                self.error = str(e)
            time.sleep(5)

    def json(self):
        return '{"temp": %d, "mhz": %d, "load": %.2f, "cpu": %d, "error": "%s"}' % (
            self.temp, self.mhz, self.load, self.cpu, self.error.replace('"', "'"))


stats = Stats()


def screen_size():
    """The mode Engine set: what the launcher wrote to /run/az01/mode, or
    failing that the connector's preferred one. fb0 still reports the
    console's mode, which is not what is on the screen any more."""
    try:
        out = subprocess.run(SSH + ["cat /run/az01/mode 2>/dev/null || for c in /sys/class/drm/card0-*; do [ \"$(cat $c/status)\" = connected ] && head -n1 $c/modes && break; done"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        w, h = out.split("x")
        return int(w), int(h)
    except Exception:
        return 1920, 1080


SIZE = None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
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
        global SIZE
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "remote.html"), "rb") as f:
                self._reply(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/config":
            if SIZE is None:
                SIZE = screen_size()
            ok = fifo.open()
            self._reply(200, '{"mirror": "/stream", "width": %d, "height": %d, "connected": %s, "error": "%s", "stream": "%s"}'
                        % (SIZE[0], SIZE[1], "true" if ok else "false", fifo.error.replace('"', "'"),
                           (frames.error or "live").replace('"', "'")),
                        "application/json")
        elif self.path == "/stats":
            self._reply(200, stats.json(), "application/json")
        elif self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            seen = -1
            try:
                while True:
                    jpeg, seen = frames.wait(seen)
                    if not jpeg:
                        continue
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(jpeg))
                    self.wfile.write(jpeg + b"\r\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if self.path != "/touch":
            return self._reply(404, "not found")
        n = int(self.headers.get("Content-Length", "0"))
        text = self.rfile.read(n).decode(errors="replace")
        # only the three verbs and a tap, nothing else reaches the board
        lines = [l for l in text.split("\n") if l and (l[0] in "dmu" or l[0].isdigit())]
        if not lines:
            return self._reply(400, "bad")
        self._reply(200 if fifo.send("\n".join(lines) + "\n") else 503, fifo.error or "ok")


def main():
    frames.start()
    stats.start()
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    url = "http://%s:%d/" % (HOST, PORT)
    print("remote desktop: %s   (board %s, mirror %s)" % (url, BOARD, MIRROR))
    if not os.environ.get("NO_BROWSER"):
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if fifo.proc:
            fifo.proc.terminate()


if __name__ == "__main__":
    main()
