"""A fake box.ascii.dev REST API for parity runs.

  python3 -I fake_box.py <port> <record.ndjson>

Boxes get deterministic ids; a new box starts "starting" and is ready on the
next read; the desktop answers `provisioning` once before giving a URL;
commands succeed (`captured` for the screenshot command, `bootstrapped` for
the bootstrap); artifacts return fixed JPEG bytes. Every request except
`/me` (the Node boxAgent driver probes the real provider instead) is
recorded with commands reduced to their sha256, so two engines can be
compared on exactly what they asked the provider to do.
"""
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT, RECORD = int(sys.argv[1]), sys.argv[2]
boxes = {}
desktop_asks = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, raw=None, ctype="application/json"):
        data = raw if raw is not None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw or b"null") if raw else None
        url = urlparse(self.path)
        path = url.path.replace("/api/box/v1", "", 1)
        if path != "/me":
            entry = {"method": method, "path": path + (("?" + url.query) if url.query else ""),
                     "auth": self.headers.get("authorization", "")[:12]}
            if body and "command" in body:
                entry["command"] = hashlib.sha256(body["command"].encode()).hexdigest()[:16]
            elif body is not None:
                entry["body"] = body
            if self.headers.get("X-Ascii-Confirm-Delete"):
                entry["confirm"] = self.headers["X-Ascii-Confirm-Delete"]
            with open(RECORD, "a") as f:
                f.write(json.dumps(entry) + "\n")
        parts = [p for p in path.split("/") if p]
        if path == "/me":
            return self.reply(200, {"ok": True, "user": {"id": "u1"}})
        if parts == ["boxes"] and method == "GET":
            return self.reply(200, {"boxes": list(boxes.values())})
        if parts == ["boxes"] and method == "POST":
            box_id = f"box-{len(boxes) + 1}"
            boxes[box_id] = {"id": box_id, "name": "", "state": "starting", "desktopAvailable": True}
            return self.reply(201, {"box": boxes[box_id]})
        # the box-native agent (boxAgent): a run that streams then finishes
        if len(parts) >= 3 and parts[2] in ("prompt", "events", "prompts", "interrupt"):
            polls = desktop_asks.get("agent", 0)
            if parts[2] == "prompt":
                desktop_asks["agent"] = 0
                return self.reply(200, {"type": "prompt.queued", "promptRun": {"id": "run-1"}, "id": parts[1]})
            if parts[2] == "events":
                desktop_asks["agent"] = polls + 1
                events = [{"id": "e1", "type": "tool.command", "command": "ls -la"},
                          {"id": "e2", "type": "response", "data": {"content": "Ciao"}}]
                if polls >= 1:
                    events.append({"id": "e3", "type": "response", "data": {"content": "Ciao dal box"}})
                return self.reply(200, {"events": events})
            if parts[2] == "prompts":
                state = "finished" if polls >= 2 else "running"
                return self.reply(200, {"promptRun": {"status": state, "result": "Ciao dal box!"}})
            return self.reply(200, {"ok": True})
        box = boxes.get(parts[1]) if len(parts) > 1 else None
        if box is None:
            return self.reply(404, {"ok": False, "message": "no such box"})
        tail = parts[2:]
        if not tail and method == "GET":
            out = dict(box)
            if box["state"] in ("starting", "resuming"):
                box["state"] = "idle"
            return self.reply(200, {"box": out})
        if not tail and method == "PATCH":
            box.update(body or {})
            return self.reply(200, {"box": box})
        if not tail and method == "DELETE":
            boxes.pop(box["id"], None)
            return self.reply(200, {"ok": True})
        if tail == ["commands"]:
            stdout = "captured\n" if "echo captured" in body["command"] else "bootstrapped\n" if "echo bootstrapped" in body["command"] else "ciao\n"
            return self.reply(200, {"exitCode": 0, "stdout": stdout, "stderr": ""})
        if tail == ["desktop"]:
            key = (box["id"], url.query)
            desktop_asks[key] = desktop_asks.get(key, 0) + 1
            if url.query == "vnc=1" and desktop_asks[key] % 2 == 1:
                return self.reply(200, {"provisioning": True})
            return self.reply(200, {"desktopUrl": f"https://desk.example/{box['id']}/{desktop_asks[key]}"})
        if tail == ["artifacts"]:
            return self.reply(200, None, raw=b"\xff\xd8JPEGFAKE", ctype="image/jpeg")
        if tail == ["stop"]:
            box["state"] = "archived"
            return self.reply(200, {"ok": True})
        if tail == ["resume"]:
            box["state"] = "resuming"
            return self.reply(200, {"ok": True})
        return self.reply(404, {"ok": False, "message": "no route"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def do_DELETE(self):
        self.handle_any("DELETE")


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
