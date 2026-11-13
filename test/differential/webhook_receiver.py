#!/usr/bin/env python3
"""webhook_receiver.py PORT LOG: a bot's webhook endpoint for the differential runs. Every POST is appended to LOG as
one JSON line (path, the sender's address, content type, the parsed body); the answer depends on the path:
/reply is a 200 text/plain reply, /html a 200 text/html one, /silent a 204, /slow answers after nine seconds (past
Webhook's seven-second timeout)."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]


class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw.decode("utf-8", "replace")
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "peer": self.client_address[0], "type": self.headers.get("Content-Type"), "body": body}) + "\n")
        if self.path.startswith("/slow"):
            time.sleep(9)
        if self.path.startswith("/silent"):
            self.send_response(204)
            self.end_headers()
            return
        text = "Pong from the hook" if self.path.startswith("/reply") else "<b>Pong</b> in HTML"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8" if self.path.startswith("/reply") else "text/html")
        self.end_headers()
        self.wfile.write(text.encode())

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Hook).serve_forever()
