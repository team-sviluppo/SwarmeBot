"""A fake OpenAI-compatible endpoint for parity runs.

Serves /v1/models and /v1/chat/completions (streamed or not). Behaves like a
Hermes Agent behind LiteLLM when asked to: echoes X-Hermes-Session-Id on
non-streamed answers under the LiteLLM-renamed header, and records every
request so a run can assert what the engine actually sent.

  python3 -I fake_openai.py <port> <record.ndjson>

Tools (only when a request carries `tools`, so the parity scenarios never
see any of this):
  STRUMENTO <tool> <text>  calls the tool whose name ends in __<tool>, with
                           {"text": <text>}, its arguments streamed in pieces
  DOPPIO <tool> <a> <b>    two calls in one answer
  CICLO <tool>             calls it again after every result (the round limit)
after a `tool` message the reply is "Risultato: " + every trailing result.
Model fake/no-tools answers 400 to any request with tools.
FAKE_OPENAI_HERMES=1 adds fake/hermes-1, owned_by hermes, to /models.
"""
import json
import os
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
            data = [{"id": "fake/echo-1"}, {"id": "fake/echo-2"}, {"id": "text-embedding-3"}]
            if os.environ.get("FAKE_OPENAI_HERMES"):
                data += [{"id": "fake/hermes-1", "owned_by": "hermes"}, {"id": "fake/no-tools"}]
            return self._json(200, {"data": data})
        return self._json(404, {"error": "no"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        session = self.headers.get("X-Hermes-Session-Id")
        entry = {
            "path": self.path, "auth": self.headers.get("Authorization", "")[:12],
            "session": bool(session), "model": body.get("model"),
            "roles": [m.get("role") for m in body.get("messages", [])],
            "last": (body.get("messages") or [{}])[-1].get("content"),
            "stream": body.get("stream"),
        }
        if "tools" in body:
            entry["tools"] = [t["function"]["name"] for t in body["tools"]]
        with open(RECORD, "a") as f:
            f.write(json.dumps(entry) + "\n")
        if "tools" in body or (body.get("messages") or [{}])[-1].get("role") == "tool":
            return self.tool_turn(body)
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


    def stream(self, deltas, finish="stop"):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(text):
            data = text.encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        for delta in deltas:
            chunk("data: " + json.dumps({"choices": [{"delta": delta}]}) + "\n\n")
        chunk("data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": finish}]}) + "\n\n")
        chunk("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 3}}) + "\n\n")
        chunk("data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def tool_turn(self, body):
        if body.get("model") == "fake/no-tools" and "tools" in body:
            return self._json(400, {"error": {"message": "this model does not support tools"}})
        messages = body.get("messages") or []
        users = [m for m in messages if m.get("role") == "user"]
        asked = str(users[-1].get("content", "")) if users else ""
        names = [t["function"]["name"] for t in body.get("tools", [])]

        def find(short):
            return next((n for n in names if n.endswith("__" + short)), None)

        def call(index, name, text):
            args = json.dumps({"text": text})
            third = max(1, len(args) // 3)
            first = {"tool_calls": [{"index": index, "id": f"call_{index}_{len(messages)}", "type": "function",
                                     "function": {"name": name, "arguments": ""}}]}
            pieces = [args[:third], args[third:2 * third], args[2 * third:]]
            return [first] + [{"tool_calls": [{"index": index, "function": {"arguments": p}}]} for p in pieces]

        if messages and messages[-1].get("role") == "tool":
            if "CICLO" in asked and names:
                return self.stream(call(0, find(asked.split("CICLO ", 1)[1].split()[0]), "ancora"), "tool_calls")
            results = []
            for m in reversed(messages):
                if m.get("role") != "tool":
                    break
                results.insert(0, m.get("content", ""))
            return self.stream([{"content": "Risultato: "}, {"content": " / ".join(results)}])
        words = asked.split()
        for verb in ("STRUMENTO", "DOPPIO", "CICLO"):
            if verb in words and names:
                rest = words[words.index(verb) + 1:]
                name = find(rest[0]) if rest else None
                if name is None:
                    return self.stream([{"content": f"nessuno strumento {rest[:1]}"}])
                if verb == "DOPPIO":
                    return self.stream([{"content": "Ne chiamo due."}] + call(0, name, rest[1]) + call(1, name, rest[2]), "tool_calls")
                return self.stream(call(0, name, " ".join(rest[1:]) or "ancora"), "tool_calls")
        tag = "con strumenti" if names else "senza strumenti"
        return self.stream([{"content": f"Risposta {tag}: "}, {"content": ",".join(names) or "-"}])


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # an interrupted turn hangs up mid-stream: expected, not news


Server(("127.0.0.1", PORT), Handler).serve_forever()
