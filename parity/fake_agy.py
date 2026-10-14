#!/usr/bin/env python3
"""A scripted `agy --print <prompt> --output-format stream-json` for parity.

init (conversation id; --conversation is echoed back), tool steps ACTIVE/DONE
and ACTIVE/ERROR, a per-step usage, then `result` with the whole response.
LENTO sleeps before its result (for interrupts). FAKE_AGY_RECORD gets argv.
"""
import json
import os
import sys
import time

argv = sys.argv[1:]
if argv == ["--version"]:
    print("agy 1.2.0")
    sys.exit(0)


def after(flag):
    return argv[argv.index(flag) + 1] if flag in argv else None


prompt = after("--print") or ""
if os.environ.get("FAKE_AGY_RECORD"):
    with open(os.environ["FAKE_AGY_RECORD"], "a") as f:
        flags = [a for a in argv if a.startswith("--") and a != "--print"]
        f.write(json.dumps({"flags": flags, "model": after("--model"), "conversation": after("--conversation"),
                            "prompt": prompt[-30:]}) + "\n")


def out(event, payload=None, **extra):
    print(json.dumps({"event": event, event: payload or {}, **extra}), flush=True)


conversation = after("--conversation") or "conv-1"
out("init", conversation_id=conversation)
if "LENTO" in prompt:
    time.sleep(10)
out("step_update", {"step_type": "tool", "step_index": 0, "state": "ACTIVE", "tool_name": "run_command"})
out("step_update", {"step_type": "tool", "step_index": 0, "state": "DONE"})
out("step_update", {"step_type": "tool", "step_index": 1, "state": "ACTIVE", "tool_name": "write_file"})
out("step_update", {"step_type": "tool", "step_index": 1, "state": "ERROR"})
out("step_update", {"step_type": "agent_response", "usage": {"input_tokens": 5, "cache_read_tokens": 1, "output_tokens": 2}})
out("result", {"status": "SUCCESS", "response": "Ciao da agy finto", "usage": {"input_tokens": 10, "cache_read_tokens": 2, "output_tokens": 4}})
