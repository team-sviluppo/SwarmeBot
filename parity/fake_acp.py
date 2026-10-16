#!/usr/bin/env python3
"""A scripted ACP agent (JSON-RPC 2.0 over stdio) for parity runs.

Speaks enough of every harness's dialect for the core and the per-driver
session settings to be exercised: cached_token auth, session/new|load (load
REPLAYS history with _meta.isReplay, plus one un-flagged chunk before the
prompt that the double gate must drop), set_model / set_mode /
set_config_option, an unknown server→client request that must be answered,
session/request_permission, and session/cancel.

The prompt picks the script: PERMESSO, LENTO, CONNETTORE <server> <text> (asks
permission for `mcp__<server>__echo`, then calls it through the mounted
server), or the default reply.
FAKE_ACP_RECORD appends one JSON line per prompt (argv + methods seen).
FAKE_ACP_STATE is a directory remembering sessions across processes.
"""
import json
import os
import subprocess
import sys
import threading
import time
import uuid

if sys.argv[1:] == ["--version"]:
    print("fake-acp 1.0.0")
    sys.exit(0)
if sys.argv[1:2] == ["models"]:  # cursor-agent's catalog, plain text
    print("Available models\n\nauto - Auto (current)\nfake-fast - Fake Fast (default)\nsonnet-x  Sonnet X")
    sys.exit(0)
if sys.argv[1:2] == ["status"]:
    print('banner\n{"isAuthenticated": true}')
    sys.exit(0)

state_dir = os.environ.get("FAKE_ACP_STATE", "/tmp/fake-acp-state")
os.makedirs(state_dir, exist_ok=True)
write_lock = threading.Lock()
methods = []
waiting = {}
cancelled = threading.Event()
session = {"model": "fake-default"}


def out(message):
    with write_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def update(session_id, body, replay=False):
    params = {"sessionId": session_id, "update": body}
    if replay:
        params["_meta"] = {"isReplay": True}
    out({"jsonrpc": "2.0", "method": "session/update", "params": params})


def chunk(session_id, text, kind="agent_message_chunk"):
    update(session_id, {"sessionUpdate": kind, "content": {"type": "text", "text": text}})


def ask(method, params):
    """A server→client request; blocks until the client answers."""
    request_id = f"srv-{uuid.uuid4().hex[:6]}"
    event = threading.Event()
    waiting[request_id] = [event, None]
    out({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    event.wait(30)
    return waiting.pop(request_id)[1]


def prompt(message):
    params = message["params"]
    sid = params["sessionId"]
    text = params["prompt"][0]["text"]
    record = os.environ.get("FAKE_ACP_RECORD")
    if record:
        with open(record, "a") as f:
            f.write(json.dumps({"argv": sys.argv[1:], "methods": methods, "prompt": text[-40:], "model": session["model"]}) + "\n")
    # an unknown server request: the client must answer, not leave us hanging
    unknown = ask("fs/read_text_file", {"sessionId": sid, "path": "/etc/hosts"})
    assert unknown.get("error", {}).get("code") == -32601, unknown
    if "CONNETTORE " in text:
        name, _, said = text.split("CONNETTORE ", 1)[1].strip().partition(" ")
        servers = {server["name"]: server for server in session.get("mcp", [])}
        if name not in servers:
            chunk(sid, f"nessun server {name} | server: {','.join(sorted(servers))}")
            return {"stopReason": "end_turn"}
        reply = ask("session/request_permission", {
            "sessionId": sid,
            "toolCall": {"toolCallId": "tc-c", "title": f"mcp__{name}__echo", "kind": "other", "rawInput": {"text": said}},
            "options": [{"optionId": "no", "name": "Rifiuta", "kind": "reject_once"},
                        {"optionId": "si", "name": "Consenti", "kind": "allow_once"}],
        })
        verdict = reply["result"]["outcome"].get("optionId", "cancelled")
        if verdict != "si":
            chunk(sid, f"permesso {verdict}, server {sorted(servers)}")
            return {"stopReason": "end_turn"}
        server = servers[name]
        env = {**os.environ, **{e["name"]: e["value"] for e in server.get("env", [])}}
        proc = subprocess.Popen([server["command"], *server["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

        def rpc(message):
            proc.stdin.write(json.dumps(message) + "\n")
            proc.stdin.flush()
            while True:
                answer = json.loads(proc.stdout.readline())
                if answer.get("id") == message["id"]:
                    return answer

        rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        result = rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "echo", "arguments": {"text": said}}})
        proc.stdin.close()
        proc.wait(5)
        chunk(sid, f"{result['result']['content'][0]['text']} | server: {','.join(sorted(servers))}")
        return {"stopReason": "end_turn"}
    if "PERMESSO" in text:
        reply = ask("session/request_permission", {
            "sessionId": sid,
            "toolCall": {"toolCallId": "tc-p", "title": "Pulizia", "kind": "execute", "rawInput": {"command": "rm -rf /tmp/swarme-acp-x"}},
            "options": [{"optionId": "no", "name": "Rifiuta", "kind": "reject_once"},
                        {"optionId": "si", "name": "Consenti", "kind": "allow_once"}],
        })
        outcome = reply["result"]["outcome"]
        chunk(sid, f"permesso: {outcome.get('optionId', outcome['outcome'])}")
        return {"stopReason": "end_turn"}
    if "LENTO" in text:
        chunk(sid, "penso", "agent_thought_chunk")
        for word in ["Sto ", "scrivendo ", "piano ", "piano ", "piano "]:
            if cancelled.wait(0.6):
                return {"stopReason": "cancelled"}
            chunk(sid, word)
        return {"stopReason": "end_turn"}
    chunk(sid, "hmm", "agent_thought_chunk")
    chunk(sid, "Ciao ")
    chunk(sid, "dal finto ACP")
    update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "Elenco", "kind": "execute", "rawInput": {"command": "ls -la"}})
    update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "completed"})
    update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-2", "title": "Lettura"})
    update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-2", "status": "failed"})
    return {"stopReason": "end_turn", "_meta": {"inputTokens": 7, "outputTokens": 3}}


def handle(message):
    method = message.get("method")
    msg_id = message.get("id")
    if method is None:  # an answer to one of our requests
        entry = waiting.get(msg_id)
        if entry:
            entry[1] = message
            entry[0].set()
        return
    methods.append(method)
    if method == "session/cancel":
        cancelled.set()
        return
    result = {}
    if method == "initialize":
        result = {"protocolVersion": 1, "authMethods": [{"id": "cached_token"}, {"id": "login"}],
                  "agentCapabilities": {"loadSession": True}, "_meta": {"modelState": {"currentModelId": "fake-default"}}}
    elif method == "session/new":
        session["mcp"] = message["params"].get("mcpServers", [])
        sid = f"sess-{uuid.uuid4().hex[:8]}"
        open(os.path.join(state_dir, sid), "w").close()
        result = {"sessionId": sid, "configOptions": [{"id": "model", "currentValue": session["model"]}]}
    elif method == "session/load":
        session["mcp"] = message["params"].get("mcpServers", [])
        sid = message["params"]["sessionId"]
        if not os.path.exists(os.path.join(state_dir, sid)):
            out({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32002, "message": "session not found"}})
            return
        update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "VECCHIO"}}, replay=True)
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "STORIA"}}, replay=True)
        # not flagged as replay, but before the prompt: must be dropped too
        chunk(sid, "PRIMA DEL PROMPT")
        result = {"configOptions": [{"id": "model", "currentValue": session["model"]}]}
    elif method in ("session/set_model",):
        session["model"] = message["params"]["modelId"]
    elif method == "session/set_config_option":
        session["model"] = message["params"]["value"]
        result = {"configOptions": [{"id": "model", "currentValue": session["model"]}]}
    elif method == "session/prompt":
        def run():
            out({"jsonrpc": "2.0", "id": msg_id, "result": prompt(message)})
        threading.Thread(target=run, daemon=True).start()
        return
    out({"jsonrpc": "2.0", "id": msg_id, "result": result})


for line in sys.stdin:
    if line.strip():
        handle(json.loads(line))
# stdin closed: the client is gone
