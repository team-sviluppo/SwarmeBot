#!/usr/bin/env python3
"""A scripted `codex app-server` for parity runs.

initialize / initialized, model/list (two pages, one hidden row), thread/start
and thread/resume (threads remembered across processes in FAKE_CODEX_STATE),
turn/start followed by notifications, and the server→client requests:
item/commandExecution/requestApproval (PERMESSO), the legacy
execCommandApproval (VECCHIO), item/tool/requestUserInput (DOMANDA). LENTO
streams slowly; an interrupt kills the process. FAKE_CODEX_RECORD gets one
line per turn with argv, thread/start params and turn/start params.
"""
import json
import os
import sys
import threading
import time
import uuid

argv = sys.argv[1:]
if argv == ["--version"]:
    print("codex-cli 0.150.0")
    sys.exit(0)
if argv[:2] == ["login", "status"]:
    print("Logged in using ChatGPT")
    sys.exit(0)

state_dir = os.environ.get("FAKE_CODEX_STATE", "/tmp/fake-codex-state")
os.makedirs(state_dir, exist_ok=True)
lock = threading.Lock()
waiting = {}
record = {"argv": argv}


def out(message):
    with lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def note(method, params):
    out({"jsonrpc": "2.0", "method": method, "params": params})


def ask(method, params):
    request_id = 900 + len(waiting)
    event = threading.Event()
    waiting[request_id] = [event, None]
    out({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    event.wait(30)
    return waiting.pop(request_id)[1]["result"]


def message(text, deltas):
    for d in deltas:
        note("item/agentMessage/delta", {"delta": d})
    note("item/completed", {"item": {"type": "agentMessage", "id": "m1", "text": text}})


def run_turn(params):
    text = params["input"][0]["text"]
    record["turn"] = {k: v for k, v in params.items() if k != "input"}
    record["prompt"] = text[-40:]
    if os.environ.get("FAKE_CODEX_RECORD"):
        with open(os.environ["FAKE_CODEX_RECORD"], "a") as f:
            f.write(json.dumps(record) + "\n")
    if "PERMESSO" in text:
        decision = ask("item/commandExecution/requestApproval", {"command": "rm -rf /tmp/swarme-codex-x", "reason": "pulizia"})["decision"]
        message(f"permesso: {decision}", [])
    elif "VECCHIO" in text:
        decision = ask("execCommandApproval", {"command": "git push --force"})["decision"]
        message(f"legacy: {decision}", ["legacy: ", decision])
    elif "DOMANDA" in text:
        answers = ask("item/tool/requestUserInput", {"questions": [
            {"id": "q1", "header": "Colore", "question": "Quale colore?", "options": [{"label": "Rosso"}, {"label": "Blu"}]}]})["answers"]
        message(f"risposta: {answers['q1']['answers'][0]}", [])
    elif "LENTO" in text:
        for word in ["Sto ", "scrivendo ", "piano ", "piano ", "piano "]:
            note("item/agentMessage/delta", {"delta": word})
            time.sleep(0.6)
    else:
        note("item/reasoning/summaryTextDelta", {"delta": "penso"})
        note("item/completed", {"item": {"type": "reasoning", "id": "r1"}})
        note("item/started", {"item": {"type": "commandExecution", "id": "c1", "command": "ls -la"}})
        note("item/completed", {"item": {"type": "commandExecution", "id": "c1", "status": "completed"}})
        note("item/started", {"item": {"type": "fileChange", "id": "f1"}})
        note("item/completed", {"item": {"type": "fileChange", "id": "f1", "status": "declined"}})
        note("item/started", {"item": {"type": "userMessage", "id": "u1"}})
        message("Ciao dal finto codex", ["Ciao ", "dal finto codex"])
        note("error", {"error": {"message": "avviso di prova"}})
    note("thread/tokenUsage/updated", {"tokenUsage": {"total": {"inputTokens": 120, "outputTokens": 30},
                                                      "last": {"inputTokens": 20, "outputTokens": 6}}})
    note("turn/completed", {"turn": {"status": "completed"}})


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    if method is None:
        entry = waiting.get(msg_id)
        if entry:
            entry[1] = msg
            entry[0].set()
        return
    if msg_id is None:
        return  # initialized
    result = {}
    if method == "initialize":
        result = {"userAgent": "fake"}
    elif method == "model/list":
        if msg["params"].get("cursor") is None:
            result = {"data": [{"id": "gpt-fake-1", "displayName": "GPT Fake 1"}, {"id": "gpt-hidden", "hidden": True}], "nextCursor": "p2"}
        else:
            result = {"data": [{"id": "gpt-fake-2", "displayName": "GPT Fake 2", "isDefault": True}], "nextCursor": None}
    elif method == "thread/start":
        tid = f"th-{len(os.listdir(state_dir)) + 1}"
        open(os.path.join(state_dir, tid), "w").close()
        record["start"] = {k: v for k, v in msg["params"].items() if k != "cwd"}
        result = {"thread": {"id": tid}, "model": msg["params"].get("model") or "gpt-fake-2"}
    elif method == "thread/resume":
        tid = msg["params"]["threadId"]
        if not os.path.exists(os.path.join(state_dir, tid)):
            out({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32600, "message": "no such thread"}})
            return
        record["resumed"] = True
        result = {"thread": {"id": tid}}
    elif method == "turn/start":
        out({"jsonrpc": "2.0", "id": msg_id, "result": {"turn": {"id": "t1"}}})
        threading.Thread(target=run_turn, args=(msg["params"],), daemon=True).start()
        return
    out({"jsonrpc": "2.0", "id": msg_id, "result": result})


for line in sys.stdin:
    if line.strip():
        handle(json.loads(line))
