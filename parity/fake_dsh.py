#!/usr/bin/env python3
"""A scripted DeepSeek Harness Host for parity runs (stdlib only).

  python3 -I fake_dsh.py <port> <record.ndjson>

Host API: POST /api/<method> (client-request → server-response), POST
/api/respond (client-response → receipt), WebSocket downlinks
/api/events.mux and /api/events.host. Paired transport mirrors all of it
under /remote/api with the device cookie; /api/pair/accept hands one out and
/api/pair/model-catalog… is the paired model-management plugin.

The prompt picks the script: PERMESSO (approval), DOMANDA (question), LENTO
(slow, until session.cancel), anything else the default reply. Every distinct
request (method + payload, minus volatile ids) is recorded once.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
COOKIE = "dsh_device=dev-1"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

lock = threading.Lock()
mux_sockets = []
recorded = set()
sessions = {}
counter = {"session": 0, "frame": 0}
waiting = {}
cancelled = {}
settings = {"revision": 3, "models": None}
catalog_models = [
    {"id": "chat", "name": "Chat", "reasoning": {"efforts": [{"id": "off", "name": "Off"}, {"id": "high", "name": "High"}]}},
    {"id": "reasoner", "name": "Reasoner", "contextWindow": 128000},
]


def record(entry):
    text = json.dumps(entry, sort_keys=True)
    with lock:
        if text in recorded:
            return
        recorded.add(text)
        with open(RECORD, "a") as f:
            f.write(text + "\n")


def ws_send(sock, text):
    data = text.encode()
    header = bytes([0x81])
    if len(data) < 126:
        header += bytes([len(data)])
    elif len(data) < 65536:
        header += bytes([126]) + struct.pack(">H", len(data))
    else:
        header += bytes([127]) + struct.pack(">Q", len(data))
    try:
        sock.sendall(header + data)
    except OSError:
        pass


def frame(method, payload):
    with lock:
        counter["frame"] += 1
        rpc = f"f-{counter['frame']}"
    message = json.dumps({"type": "server-request", "rpcId": rpc, "method": method, "payload": {"type": method, **payload}})
    for sock in list(mux_sockets):
        ws_send(sock, message)
    return rpc


def event(session, kind, data):
    return frame("session/event", {"sessionId": session, "event": {"type": kind, "seq": counter["frame"], "time": 1, "data": data}})


def ask(method, payload):
    done = threading.Event()
    with lock:
        counter["frame"] += 1
        rpc = f"ask-{counter['frame']}"
        waiting[rpc] = [done, None]
    message = json.dumps({"type": "server-request", "rpcId": rpc, "method": method, "payload": {"type": method, **payload}})
    for sock in list(mux_sockets):
        ws_send(sock, message)
    done.wait(30)
    return rpc, waiting.pop(rpc)[1]


def run_prompt(session, text):
    time.sleep(0.15)
    sessions[session] += 1
    turn = sessions[session]
    event(session, "turn/start", {"turn": turn})
    if "PERMESSO" in text:
        rpc, reply = ask("approval/requested", {"sessionId": session, "approvalId": "a1", "toolName": "bash", "reason": "rm -rf /tmp/swarme-dsh-x"})
        outcome = reply["result"]["value"]["outcome"]
        frame("approval/resolved", {"sessionId": session, "approvalId": "a1", "outcome": outcome})
        reply_text = f"permesso: {outcome}"
    elif "DOMANDA" in text:
        rpc, reply = ask("question/requested", {"sessionId": session, "questions": [
            {"id": "q1", "question": "Quale colore?", "options": [{"label": "Rosso"}, {"label": "Blu"}]}]})
        answer = reply["result"]["value"]["answer"]["answers"][0]
        frame("question/resolved", {"sessionId": session, "questionRpcId": rpc, "outcome": "answered"})
        reply_text = f"risposta: {answer.get('selected')} {answer.get('custom')}"
    elif "LENTO" in text:
        for word in ["Sto ", "scrivendo ", "piano ", "piano ", "piano "]:
            if cancelled.get(session):
                cancelled[session] = False
                event(session, "turn/end", {"turn": turn, "reason": {"kind": "cancelled"}})
                return
            event(session, "assistant/chunk", {"turn": turn, "chunk": {"type": "text-delta", "text": word}})
            time.sleep(0.6)
        reply_text = "Sto scrivendo piano piano piano "
    else:
        event(session, "assistant/chunk.reasoning-delta", {"turn": turn, "delta": "penso"})
        event(session, "assistant/chunk", {"turn": turn, "chunk": {"type": "text-delta", "text": "Ciao "}})
        event(session, "assistant/chunk.text-delta", {"turn": turn, "delta": "dal finto DSH"})
        event(session, "tool/call", {"turn": turn, "callId": "c1", "name": "bash"})
        event(session, "tool/result", {"turn": turn, "message": {"source": {"callId": "c1"}, "content": [{"type": "text", "isError": False}]}})
        event(session, "tool/call", {"turn": turn, "callId": "c2", "name": "read"})
        event(session, "tool/result", {"turn": turn, "message": {"source": {"callId": "c2"}, "content": [{"type": "text", "isError": True}]}})
        reply_text = "Ciao dal finto DSH"
    event(session, "assistant/message", {"turn": turn, "message": {"content": [{"type": "text", "text": reply_text}]}, "usage": {"inputTokens": 5, "outputTokens": 3}})
    event(session, "turn/end", {"turn": turn, "reason": {"kind": "completed"}, "usage": {"inputTokens": 9, "outputTokens": 4}})


def provider_profile():
    profile = {"apiKey": "secret"}
    if settings["models"] is not None:
        profile["models"] = settings["models"]
    return profile


def unary(method, payload):
    if method == "host.describe":
        return {"version": "fake-dsh 1.0", "cwd": "/", "attachedSessions": 0, "home": "/", "canOpenPath": False}
    if method == "llm.models":
        models = list(catalog_models)
        for row in settings["models"] or []:
            if not any(m["id"] == row["id"] for m in models):
                models.append({"id": row["id"], "name": row.get("name", row["id"])})
        return {"groups": [{"id": "deepseek", "name": "DeepSeek", "models": models}], "failures": []}
    if method == "session.create":
        if payload.get("sessionId"):
            sessions.setdefault(payload["sessionId"], 0)
            return {"sessionId": payload["sessionId"]}
        counter["session"] += 1
        sid = f"dsh-s-{counter['session']}"
        sessions[sid] = 0
        return {"sessionId": sid}
    if method == "session.selectModel":
        selected = {"provider": payload["provider"], "model": payload["model"]}
        if "reasoningEffort" in payload:
            selected["reasoningEffort"] = payload["reasoningEffort"]
        return {"selected": selected}
    if method == "session.prompt":
        threading.Thread(target=run_prompt, args=(payload["sessionId"], payload["content"][0]["text"]), daemon=True).start()
        return {"accepted": True}
    if method == "session.cancel":
        cancelled[payload["sessionId"]] = True
        return {"accepted": True}
    if method == "llm.providers":
        return {"providers": [
            {"provider": "deepseek", "displayName": "DeepSeek", "settingsNs": "llm-pi-ai", "settingsPath": ["providers", "deepseek"], "active": True},
            {"provider": "other", "displayName": "Other", "settingsNs": "llm-other", "settingsPath": ["x"], "active": True},
        ]}
    if method == "settings.describe":
        return {"writable": True, "hasDocument": True, "namespaces": [{
            "ns": "llm-pi-ai", "schema": {}, "value": {"providers": {"deepseek": provider_profile()}},
            "applies": "live", "secrets": [], "revision": settings["revision"]}]}
    if method == "llm.discoverModels":
        return {"models": [{"id": "chat"}, {"id": "new-model", "name": "Nuovo", "contextWindow": 64000}]}
    if method == "settings.mutate":
        for op in payload["ops"]:
            if op["op"] == "set" and op["path"][-1] == "models":
                settings["models"] = op["value"]
        settings["revision"] += 1
        return {"ns": "llm-pi-ai", "schema": {}, "value": {}, "applies": "live", "secrets": [], "revision": settings["revision"]}
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def api_path(self):
        """The Host API path under /api, or None if the paired cookie is missing."""
        if self.path.startswith("/remote/api/"):
            if self.headers.get("Cookie") != COOKIE:
                return None
            return self.path[len("/remote/api/"):]
        if self.path.startswith("/api/"):
            return self.path[len("/api/"):]
        return None

    def do_GET(self):
        if self.path == "/api/pair/model-catalog":
            if self.headers.get("Cookie") != COOKIE:
                return self.reply(401, {})
            return self.reply(200, {"capability": "paired-model-catalog", "providers": [{"provider": "deepseek", "displayName": "DeepSeek"}]})
        name = self.api_path()
        if name not in ("events.mux", "events.host") or self.headers.get("Upgrade", "").lower() != "websocket":
            return self.reply(404, {})
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        sock = self.connection
        if name == "events.mux":
            mux_sockets.append(sock)
        try:
            while True:
                head = sock.recv(2)
                if len(head) < 2:
                    break
                opcode, length = head[0] & 0x0F, head[1] & 0x7F
                if length == 126:
                    length = struct.unpack(">H", sock.recv(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", sock.recv(8))[0]
                mask = sock.recv(4) if head[1] & 0x80 else b""
                payload = b""
                while len(payload) < length:
                    chunk = sock.recv(length - len(payload))
                    if not chunk:
                        break
                    payload += chunk
                if opcode == 0x8:
                    try:
                        sock.sendall(bytes([0x88, 0]))
                    except OSError:
                        pass
                    break
                if opcode == 0x9:  # ping → pong
                    data = bytes(b ^ mask[i % 4] for i, b in enumerate(payload)) if mask else payload
                    sock.sendall(bytes([0x8A, len(data)]) + data)
        except OSError:
            pass
        finally:
            if sock in mux_sockets:
                mux_sockets.remove(sock)
        self.close_connection = True

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"null")
        if self.path == "/api/pair/accept":
            record({"pair": body})
            if body.get("token") != "tok123":
                return self.reply(403, {})
            return self.reply(200, {"ok": True}, {"Set-Cookie": f"{COOKIE}; Path=/; HttpOnly; SameSite=Strict"})
        if self.path.startswith("/api/pair/model-catalog/"):
            if self.headers.get("Cookie") != COOKIE:
                return self.reply(401, {})
            action = self.path.rsplit("/", 1)[1]
            record({"paired": action, "body": body})
            if action == "discover":
                return self.reply(200, {"models": [{"id": "paired-model"}]})
            return self.reply(200, unary("llm.models", {}))
        name = self.api_path()
        if name is None:
            return self.reply(401, {})
        if name == "respond":
            with lock:
                entry = waiting.get(body["rpcId"])
            if not entry:
                return self.reply(200, {"accepted": False, "reason": "not-pending"})
            record({"respond": body["result"]})
            entry[1] = dict(body)
            # the receipt goes out before the turn moves on, so the Host's own
            # *resolved frame never races the client's answer
            self.reply(200, {"accepted": True})
            self.wfile.flush()
            time.sleep(0.2)
            entry[0].set()
            return
        payload = body.get("payload") or {}
        logged = json.loads(json.dumps(payload))
        if isinstance(logged, dict) and name == "session.prompt":
            logged["content"] = [{"type": "text", "tail": logged["content"][0]["text"][-30:],
                                  "persona": logged["content"][0]["text"].startswith("<swarmebot-persona>")}]
        record({"method": name, "via": self.path.split("/")[1],
                "payload": {k: v for k, v in logged.items() if k not in ("cwd",)} if isinstance(logged, dict) else logged})
        value = unary(name, payload)
        if value is None:
            return self.reply(200, {"type": "server-response", "rpcId": body["rpcId"],
                                    "result": {"ok": False, "error": {"code": "unknown-command", "message": "no", "details": {}}}})
        return self.reply(200, {"type": "server-response", "rpcId": body["rpcId"], "result": {"ok": True, "value": value}})


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # clients drop their sockets on teardown; that is not news


Server(("127.0.0.1", PORT), Handler).serve_forever()
