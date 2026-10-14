"""A fake OpenAI-compatible endpoint for parity runs.

Serves /v1/models and /v1/chat/completions (streamed or not). Behaves like a
Hermes Agent behind LiteLLM when asked to: echoes X-Hermes-Session-Id on
non-streamed answers under the LiteLLM-renamed header, and records every
request so a run can assert what the engine actually sent.

  python3 -I fake_openai.py <port> <record.ndjson>
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
REPLY = ["Ciao! ", "Sono il ", "modello finto."]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.endswith("/models"):
            return self._json(200, {"data": [{"id": "fake/echo-1"}, {"id": "fake/echo-2"}, {"id": "text-embedding-3"}]})
        return self._json(404, {"error": "no"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        session = self.headers.get("X-Hermes-Session-Id")
        with open(RECORD, "a") as f:
            f.write(json.dumps({
                "path": self.path, "auth": self.headers.get("Authorization", "")[:12],
                "session": bool(session), "model": body.get("model"),
                "roles": [m.get("role") for m in body.get("messages", [])],
                "last": (body.get("messages") or [{}])[-1].get("content"),
                "stream": body.get("stream"),
            }) + "\n")
        if not body.get("stream"):
            headers = {"llm_provider-x-hermes-session-id": session} if session else {}
            return self._json(200, {"choices": [{"message": {"content": "".join(REPLY)}}],
                                    "usage": {"prompt_tokens": 7, "completion_tokens": 5}}, headers)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(text):
            data = text.encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        last = str((body.get("messages") or [{}])[-1].get("content", ""))
        slow = "LENTO" in last
        pieces = ["parola "] * 12 if slow else REPLY
        try:
            for piece in pieces:
                chunk("data: " + json.dumps({"choices": [{"delta": {"content": piece}}]}) + "\n\n")
                if slow:
                    time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            return
        chunk("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 5}}) + "\n\n")
        chunk("data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # an interrupted turn hangs up mid-stream: expected, not news


Server(("127.0.0.1", PORT), Handler).serve_forever()
