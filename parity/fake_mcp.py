"""A fake MCP server for the connector tests.

  python3 -I fake_mcp.py stdio [record.ndjson]
  python3 -I fake_mcp.py http <port> [record.ndjson]

Tools:
  echo(text)   -> the text back; also reports FAKE_MCP_SECRET's length so a
                  test can see the env reached the server without printing it
  slow(seconds)-> answers after a pause (interrupts, timeouts)
  fail()       -> isError: true
  big(n)       -> n characters of text
  headers()    -> (http) the request headers the server saw, as JSON
  forget()     -> (http) drops every session: the next request gets a 404
  die()        -> (stdio) the process exits without answering

tools/list pages two tools at a time, so the client must follow nextCursor.
HTTP mode answers `initialize` with an Mcp-Session-Id and requires it after;
`tools/call` answers as an SSE stream, everything else as plain JSON. A
request with header `X-Fake-Auth: wrong` is refused with 401.
Every message received is appended to the record file, when one is given.

FAKE_MCP_OAUTH=1 (http) puts the MCP endpoint behind OAuth, as the MCP
authorization spec has it: a 401 naming the protected-resource metadata,
an authorization server under /auth with dynamic registration, PKCE (S256)
and `resource` checked, access tokens that live FAKE_MCP_TOKEN_TTL seconds
(default 3600) and refresh tokens. POST /control/revoke forgets every token
and GET /control/stats counts the grants, for the tests.
"""
import base64
import hashlib
import json
import os
import urllib.parse
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1]
RECORD = sys.argv[3] if MODE == "http" and len(sys.argv) > 3 else (sys.argv[2] if MODE == "stdio" and len(sys.argv) > 2 else None)
TOOLS = [
    {"name": "echo", "description": "Echo the text back.", "annotations": {"readOnlyHint": True},
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "slow", "description": "Answer after a pause.",
     "inputSchema": {"type": "object", "properties": {"seconds": {"type": "number"}}}},
    {"name": "fail", "description": "Always fails.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "big", "description": "A long text.",
     "inputSchema": {"type": "object", "properties": {"n": {"type": "integer"}}}},
    {"name": "headers", "description": "The request headers.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "forget", "description": "Drop the HTTP sessions.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "die", "description": "Exit the process.", "inputSchema": {"type": "object", "properties": {}}},
]
lock = threading.Lock()


def record(message):
    if not RECORD:
        return
    with lock:
        with open(RECORD, "a") as f:
            f.write(json.dumps(message) + "\n")


def text(value, error=False):
    out = {"content": [{"type": "text", "text": value}]}
    if error:
        out["isError"] = True
    return out


def handle(message, seen_headers=None):
    """The response for one request, or None for a notification."""
    record(message)
    method = message.get("method")
    if "id" not in message:
        return None
    rid = message["id"]
    params = message.get("params") or {}
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {"listChanged": True}},
                  "serverInfo": {"name": "fake-mcp", "version": "0.1"},
                  "instructions": "A fake server."}
    elif method == "tools/list":
        start = int(params.get("cursor") or 0)
        page = TOOLS[start:start + 2]
        result = {"tools": page}
        if start + 2 < len(TOOLS):
            result["nextCursor"] = str(start + 2)
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "echo":
            secret = os.environ.get("FAKE_MCP_SECRET", "")
            result = text(f"{args.get('text', '')} (secret len {len(secret)})")
        elif name == "slow":
            time.sleep(float(args.get("seconds", 2)))
            result = text("done")
        elif name == "fail":
            result = text("it broke", error=True)
        elif name == "big":
            result = text("x" * int(args.get("n", 1000)))
        elif name == "headers":
            result = text(json.dumps(seen_headers or {}))
        elif name == "forget":
            SESSIONS.clear()
            result = text("forgotten")
        elif name == "die":
            os._exit(3)
        else:
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": f"unknown tool {name}"}}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def run_stdio():
    sys.stderr.write("fake-mcp starting\n")
    sys.stderr.flush()
    write_lock = threading.Lock()

    def answer(message):
        response = handle(message)
        if response is not None:
            with write_lock:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        # slow calls must not block the next request
        threading.Thread(target=answer, args=(message,), daemon=True).start()


SESSIONS = set()
OAUTH = os.environ.get("FAKE_MCP_OAUTH") == "1"
TTL = float(os.environ.get("FAKE_MCP_TOKEN_TTL", "3600"))
CLIENTS = {}     # client_id -> redirect_uris
CODES = {}       # code -> (client_id, redirect_uri, challenge, resource)
ACCESS = {}      # token -> expiry
REFRESH = set()
STATS = {"authorization_code": 0, "refresh_token": 0, "register": 0}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, status, body=b"", content_type="application/json", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def base(self):
        return f"http://{self.headers.get('Host')}"

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/.well-known/oauth-protected-resource/mcp" and OAUTH:
            return self._send(200, json.dumps({"resource": self.base() + "/mcp", "authorization_servers": [self.base() + "/auth"],
                                               "scopes_supported": ["mcp:tools"]}).encode())
        if url.path == "/.well-known/oauth-authorization-server/auth" and OAUTH:
            b = self.base() + "/auth"
            return self._send(200, json.dumps({"issuer": b, "authorization_endpoint": b + "/authorize", "token_endpoint": b + "/token",
                                               "registration_endpoint": b + "/register", "code_challenge_methods_supported": ["S256"]}).encode())
        if url.path == "/auth/authorize" and OAUTH:
            client, redirect = query.get("client_id"), query.get("redirect_uri")
            if redirect not in CLIENTS.get(client, []):
                return self._send(400, b'{"error":"unknown client or redirect"}')
            if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
                return self._send(400, b'{"error":"PKCE required"}')
            if query.get("resource") != self.base() + "/mcp":
                return self._send(400, b'{"error":"wrong resource"}')
            code = uuid.uuid4().hex
            CODES[code] = (client, redirect, query["code_challenge"], query["resource"])
            # the user said yes at once
            location = redirect + "?" + urllib.parse.urlencode({"code": code, "state": query.get("state", "")})
            return self._send(302, headers={"Location": location})
        if url.path == "/control/stats":
            return self._send(200, json.dumps(STATS).encode())
        self._send(404, b'{"error":"not found"}')

    def oauth_post(self, path, raw):
        if path == "/auth/register":
            body = json.loads(raw)
            client = f"client-{len(CLIENTS) + 1}"
            CLIENTS[client] = body.get("redirect_uris", [])
            STATS["register"] += 1
            return self._send(201, json.dumps({"client_id": client, "redirect_uris": CLIENTS[client]}).encode())
        if path == "/auth/token":
            form = dict(urllib.parse.parse_qsl(raw.decode()))
            grant = form.get("grant_type")
            if grant == "authorization_code":
                entry = CODES.pop(form.get("code"), None)
                if not entry or entry[0] != form.get("client_id") or entry[1] != form.get("redirect_uri"):
                    return self._send(400, b'{"error":"invalid_grant"}')
                if b64url(hashlib.sha256(form.get("code_verifier", "").encode()).digest()) != entry[2]:
                    return self._send(400, b'{"error":"invalid_grant","error_description":"PKCE mismatch"}')
            elif grant == "refresh_token":
                if form.get("refresh_token") not in REFRESH:
                    return self._send(400, b'{"error":"invalid_grant","error_description":"refresh token revoked"}')
                REFRESH.discard(form["refresh_token"])
            else:
                return self._send(400, b'{"error":"unsupported_grant_type"}')
            STATS[grant] += 1
            access, refresh = "at-" + uuid.uuid4().hex, "rt-" + uuid.uuid4().hex
            ACCESS[access] = time.time() + TTL
            REFRESH.add(refresh)
            return self._send(200, json.dumps({"access_token": access, "token_type": "Bearer", "expires_in": TTL,
                                               "refresh_token": refresh}).encode())
        if path == "/control/revoke":
            ACCESS.clear()
            REFRESH.clear()
            return self._send(200, b"{}")
        return False  # not an OAuth path; every handled path returned _send's None

    def do_DELETE(self):
        SESSIONS.discard(self.headers.get("Mcp-Session-Id"))
        self._send(200)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        path = urllib.parse.urlparse(self.path).path
        if path.startswith(("/auth/", "/control/")):
            if self.oauth_post(path, raw) is False:
                self._send(404, b'{"error":"not found"}')
            return
        if OAUTH:
            token = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
            if ACCESS.get(token, 0) < time.time():
                meta = self.base() + "/.well-known/oauth-protected-resource/mcp"
                return self._send(401, b'{"error":"unauthorized"}',
                                  headers={"WWW-Authenticate": f'Bearer resource_metadata="{meta}", scope="mcp:tools"'})
        if not raw.strip():
            sys.stderr.write(f"empty POST {self.path} {dict(self.headers)}\n")
            return self._send(400, b'{"error":"empty body"}')
        message = json.loads(raw)
        if self.headers.get("X-Fake-Auth") == "wrong":
            return self._send(401, b'{"error":"bad credentials"}')
        session = self.headers.get("Mcp-Session-Id")
        extra = {}
        if message.get("method") == "initialize":
            session = uuid.uuid4().hex
            SESSIONS.add(session)
            extra["Mcp-Session-Id"] = session
        elif session not in SESSIONS:
            return self._send(404 if session else 400, b'{"error":"no session"}')
        seen = {k: v for k, v in self.headers.items()}
        response = handle(message, seen)
        if response is None:
            return self._send(202, headers=extra)
        if message.get("method") == "tools/call":
            body = ("event: message\ndata: " + json.dumps(response) + "\n\n").encode()
            return self._send(200, body, "text/event-stream", extra)
        self._send(200, json.dumps(response).encode(), headers=extra)


if MODE == "stdio":
    run_stdio()
else:
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
