#!/usr/bin/env python3
"""A scripted `pi --mode rpc --no-session` for parity runs.

get_available_models, new_session (a sessionFile) / switch_session, set_model,
prompt → message_update deltas, tool_execution_*, a `turn_end` with
stopReason toolUse that must NOT settle, then `agent_end`. PERMESSO asks
`confirm`, DOMANDA asks `input` (after a setStatus that must be ignored),
LENTO streams slowly until `abort`. FAKE_PI_RECORD gets one line per prompt.
"""
import json
import os
import sys
import threading
import time

argv = sys.argv[1:]
if argv == ["--version"]:
    print("0.99.0")
    sys.exit(0)

lock = threading.Lock()
answers = {}
aborted = threading.Event()
record = {"argv": argv, "commands": []}


def out(message):
    with lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def respond(command, data=None, success=True):
    out({"type": "response", "command": command, "success": success, "data": data})


def text(delta, kind="text_delta"):
    out({"type": "message_update", "assistantMessageEvent": {"type": kind, "delta": delta}})


def ask(method, title):
    request_id = f"ui-{len(answers) + 1}"
    event = threading.Event()
    answers[request_id] = [event, None]
    out({"type": "extension_ui_request", "id": request_id, "method": method, "title": title})
    event.wait(30)
    return answers[request_id][1]


def prompt(message):
    record["prompt"] = message[-40:]
    if os.environ.get("FAKE_PI_RECORD"):
        with open(os.environ["FAKE_PI_RECORD"], "a") as f:
            f.write(json.dumps(record) + "\n")
    usage = {"input": 9, "output": 4}
    if "PERMESSO" in message:
        reply = ask("confirm", "Cancello la cartella?")
        text("confermato" if reply.get("confirmed") else "annullato")
    elif "DOMANDA" in message:
        out({"type": "extension_ui_request", "id": "st-1", "method": "setStatus", "title": "lavoro"})
        reply = ask("input", "Quale colore?")
        text(f"risposta: {reply.get('value')}")
    elif "LENTO" in message:
        for word in ["Sto ", "scrivendo ", "piano ", "piano ", "piano "]:
            if aborted.wait(0.6):
                return
            text(word)
    else:
        text("hmm", "thinking_delta")
        out({"type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash"})
        out({"type": "tool_execution_end", "toolCallId": "t1", "isError": False})
        out({"type": "tool_execution_start", "toolCallId": "t2", "toolName": "read"})
        out({"type": "tool_execution_end", "toolCallId": "t2", "isError": True})
        out({"type": "turn_end", "message": {"stopReason": "toolUse"}})
        text("Ciao ")
        text("dal finto pi")
    out({"type": "agent_end", "message": {"stopReason": "stop", "usage": usage}})


for line in sys.stdin:
    if not line.strip():
        continue
    message = json.loads(line)
    kind = message.get("type")
    record["commands"].append(kind)
    if kind == "get_available_models":
        respond(kind, {"models": [{"provider": "fake", "id": "uno", "name": "Fake Uno"}, {"provider": "fake", "id": "due/bis"}]})
    elif kind == "new_session":
        respond(kind, {"sessionFile": "/sessions/s-1.jsonl", "sessionId": "s-1"})
    elif kind == "switch_session":
        record["resumed"] = message.get("sessionPath")
        respond(kind, {})
    elif kind == "set_model":
        record["model"] = [message.get("provider"), message.get("modelId")]
        respond(kind, {})
    elif kind == "prompt":
        threading.Thread(target=prompt, args=(message["message"],), daemon=True).start()
    elif kind == "abort":
        aborted.set()
    elif kind == "extension_ui_response":
        entry = answers.get(message["id"])
        if entry:
            entry[1] = message
            entry[0].set()
