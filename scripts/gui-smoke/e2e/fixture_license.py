"""Serve the existing Pro response fixture on a private, dynamically assigned loopback port."""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from threading import Thread
from urllib.parse import urlsplit


KEY = "sk-" + "E" * 43


@contextmanager
def license_server():
    repo = Path(__file__).resolve().parents[3]
    fixture = repo / "checks/SkyStudio/Fixtures/me-pro-v1.json"
    plan = json.loads(fixture.read_text())
    now = datetime.now(timezone.utc)
    plan["server_time"] = now.isoformat(timespec="seconds")
    plan["skycut"]["valid_until"] = (now + timedelta(days=1)).isoformat(timespec="seconds")
    plan["skycut"]["paid_until"] = (now + timedelta(days=30)).isoformat(timespec="seconds")
    plan["credits"]["balance"] = 0
    payload = json.dumps(plan).encode()
    unexpected = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path != "/api/skycut/v1/me" or self.headers.get("Authorization") != f"Bearer {KEY}":
                unexpected.append(("GET", path))
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            unexpected.append(("POST", urlsplit(self.path).path))
            self.send_error(405)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/api/skycut/v1"
            assert not unexpected, f"Unexpected fixture requests: {unexpected}"
        finally:
            server.shutdown()
            thread.join()
