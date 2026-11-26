#!/usr/bin/env python3
"""Local web server for scripts/smoke.sh.

Serves the test pages on 127.0.0.1 only, on a free port it writes to --port-file, plus two endpoints:

  /download/<name>?seconds=S&size=N  an attachment of N bytes sent slowly over about S seconds
  /cancel/<name>                     ends that download early (the browser marks it interrupted)

Pages are sent with no-store so Chrome never shows a cached copy from an earlier run.
"""

import argparse
import os
import re
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

CANCELLED = set()
CANCELLED_LOCK = threading.Lock()
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,120}$")


class Handler(SimpleHTTPRequestHandler):
    server_version = "UseMacSmoke/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.split("/") if p]
        if len(parts) == 2 and parts[0] == "download":
            return self.slow_download(parts[1], parse_qs(url.query))
        if len(parts) == 2 and parts[0] == "cancel":
            return self.cancel(parts[1])
        return super().do_GET()

    def cancel(self, name):
        with CANCELLED_LOCK:
            CANCELLED.add(name)
        self.send_response(204)
        self.end_headers()

    def slow_download(self, name, query):
        if not SAFE_NAME.match(name):
            self.send_error(400, "bad name")
            return
        seconds = max(0.5, min(120.0, float(query.get("seconds", ["10"])[0])))
        size = max(1024, min(64 * 1024 * 1024, int(query.get("size", ["524288"])[0])))
        chunks = 40
        chunk = max(1, size // chunks)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        sent = 0
        try:
            while sent < size:
                with CANCELLED_LOCK:
                    if name in CANCELLED:
                        # Closing early makes the browser mark the download as interrupted.
                        self.close_connection = True
                        return
                n = min(chunk, size - sent)
                self.wfile.write(b"u" * n)
                self.wfile.flush()
                sent += n
                if sent < size:
                    time.sleep(seconds / chunks)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    root = os.path.abspath(args.root)

    def handler(*a, **kw):
        return Handler(*a, directory=root, **kw)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    httpd.daemon_threads = True
    tmp = args.port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(httpd.server_address[1]))
    os.replace(tmp, args.port_file)
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
