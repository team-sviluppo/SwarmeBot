#!/usr/bin/env python3
"""A scripted `claude` CLI for parity runs: stream-json out, the prompt in
over stdin, and — unlike server/testing/fake-claude-cli.ts — a real MCP
round trip through the permission proxy named in --mcp-config, so the broker,
the proxy and the approval cards are exercised on both engines.

The prompt picks the script:
  PERMESSO  asks `approve` for a destructive Bash command, reports the verdict
  DOMANDA   asks `ask_user` with choices, reports the answer
  LENTO     streams slowly (for interrupts)
  CONNETTORE <server> <text>  calls `echo` on that connector, lists the mounted servers
  anything else: streamed text, one tool call, a result

FAKE_CLAUDE_RECORD appends one JSON line per turn: the flags that matter, and
with FAKE_CLAUDE_RECORD_SYSTEM=1 the system prompt text too.
"""
import json
import os
import subprocess
import sys
import time

argv = sys.argv[1:]


def after(flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


if argv[:1] == ["--version"]:
    print("2.1.232 (Claude Code)")
    sys.exit(0)
if argv[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai"}))
    sys.exit(0)

line = sys.stdin.readline()
prompt = json.loads(line)["message"]["content"] if line.strip() else ""
session = after("--resume") or after("--session-id") or "fake-session"

record = os.environ.get("FAKE_CLAUDE_RECORD")
if record:
    with open(record, "a") as f:
        f.write(json.dumps({
            "resume": "--resume" in argv,
            "permissionMode": after("--permission-mode"),
            "model": after("--model"),
            "effort": after("--effort"),
            "system": after("--append-system-prompt") is not None,
            "promptTool": after("--permission-prompt-tool"),
            "allowedTools": after("--allowedTools"),
            "prompt": prompt,
            "apiKeyLeaked": "ANTHROPIC_API_KEY" in os.environ,
            # opt-in, so the parity traces stay as they were
            **({"systemPrompt": after("--append-system-prompt")} if os.environ.get("FAKE_CLAUDE_RECORD_SYSTEM") else {}),
        }) + "\n")

out({"type": "system", "subtype": "init", "session_id": session, "model": after("--model") or "claude-fake"})


def mcp_call(tool, arguments, server_name="ogb"):
    """One tools/call through a server named in --mcp-config."""
    config = json.load(open(after("--mcp-config")))["mcpServers"][server_name]
    server = subprocess.Popen([config["command"], *config["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              env={**os.environ, **config.get("env", {})}, text=True)

    def rpc(message):
        server.stdin.write(json.dumps(message) + "\n")
        server.stdin.flush()
        while True:
            reply = json.loads(server.stdout.readline())
            if reply.get("id") == message["id"]:
                return reply

    rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
    tools = [t["name"] for t in rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]]
    if server_name == "computer":
        assert "ping" in tools, tools
    elif server_name in ("ogb", "agents"):
        assert tools == (["approve", "ask_user"] if server_name == "ogb" else ["list_bots", "ask_bot", "delegate_bot"]), tools
    reply = rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": tool, "arguments": arguments}})
    server.stdin.close()
    server.wait(5)
    return reply["result"]["content"][0]["text"]


def delta(text):
    out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}})


def finish(text, tool=True):
    content = [{"type": "text", "text": text}]
    if tool:
        content.append({"type": "tool_use", "id": "tu-1", "name": "Bash"})
    out({"type": "assistant", "message": {"content": content, "usage": {"input_tokens": 10, "cache_read_input_tokens": 2, "output_tokens": 5}}})
    if tool:
        out({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tu-1", "is_error": False}]}})
    out({"type": "result", "is_error": False, "stop_reason": "end_turn", "total_cost_usd": 0.01,
         "usage": {"input_tokens": 10, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3, "output_tokens": 5}})


def peer_id(name):
    """The id list_bots gives for a bot name."""
    listing = mcp_call("list_bots", {}, "agents")
    for line in listing.splitlines():
        if line.startswith(f"- {name}"):
            return line.split("[id: ")[1].split(",")[0]
    return "missing"


if "CONNETTORE " in prompt:
    name, _, text = prompt.split("CONNETTORE ", 1)[1].strip().partition(" ")
    config = after("--mcp-config")
    servers = sorted(json.load(open(config))["mcpServers"]) if config else []
    answer = mcp_call("echo", {"text": text}, name) if name in servers else f"nessun server {name}"
    finish(f"{answer} | server: {','.join(s for s in servers if s != 'ogb')} | allowed: {after('--allowedTools')}", tool=False)
elif "COMPUTER" in prompt and "PERMESSO" not in prompt and "DOMANDA" not in prompt:
    answer = mcp_call("ping", {}, "computer")
    finish(answer, tool=False)
elif prompt.startswith("CHIEDI ") or prompt.startswith("DELEGA "):
    verb, rest = prompt.split(" ", 1)
    name, message = rest.split(":", 1)
    target = peer_id(name.strip())
    if verb == "CHIEDI":
        answer = mcp_call("ask_bot", {"bot_id": target, "message": message.strip()}, "agents")
    else:
        answer = mcp_call("delegate_bot", {"bot_id": target, "message": message.strip(), "reason": "prova"}, "agents")
    finish(f"{name.strip()}: {answer}", tool=False)
elif prompt.endswith("(Reply to the conversation above as Alfa.)") and "CATENA" in prompt[-300:]:
    # a room reply that summons a teammate: the harness chains one hop
    finish("Passo la parola a @Beta", tool=False)
elif "PERMESSO" in prompt:
    verdict = json.loads(mcp_call("approve", {"tool_name": "Bash", "input": {"command": "rm -rf /tmp/swarme-parity-x"}}))
    finish(f"permesso: {verdict['behavior']}", tool=False)
elif "DOMANDA" in prompt:
    answer = mcp_call("ask_user", {"question": "Quale colore?", "choices": ["Rosso", "Blu"]})
    finish(f"risposta: {answer}", tool=False)
elif "LENTO" in prompt:
    out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "hmm"}}})
    for word in ["Sto ", "scrivendo ", "piano ", "piano ", "piano "]:
        delta(word)
        time.sleep(0.6)
    finish("Sto scrivendo piano piano piano ", tool=False)
else:
    out({"type": "system", "subtype": "thinking_tokens", "estimated_tokens": 12})
    delta("Ciao ")
    delta("dal finto claude")
    out({"type": "stream_event", "parent_tool_use_id": "task-1",
         "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "RUMORE SUBAGENTE"}}})
    finish("Ciao dal finto claude")
