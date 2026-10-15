"""Connectors end to end on the Swift engine (docs/plans/2026-10-15-connettori-mcp.md §10).

  python3 -I connectors_e2e.py <swift-binary> [claude|codex|acp:<driverKind> ...]

For each engine: a bot gets two connectors (both `fake_mcp.py stdio`), one on
by default and one off; a turn calls `echo` through the real proxy and pool;
the conversation's switches flip which one is mounted; deleting a connector
clears it from the bot and the task. Assertions, not a trace: the Node engine
never had connectors, so there is nothing to compare against.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

BIN = sys.argv[1]
DRIVERS = sys.argv[2:] or ["claude", "codex", "acp:geminiAgent", "acp:kimiAgent"]
HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_MCP = os.path.join(HERE, "fake_mcp.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def request(port, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def run(driver):
    data_dir = tempfile.mkdtemp(prefix="conn-e2e-")
    port = free_port()
    instance_id = "acp" if driver.startswith("acp:") else driver
    cli = {"claude": "fake_claude.py", "codex": "fake_codex.py"}.get(driver, "fake_acp.py")
    kind = {"claude": "claudeAgent", "codex": "codex"}.get(driver, driver[4:])
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump({"instances": {instance_id: {"driver": kind, "config": {"cli": os.path.join(HERE, cli)}}}}, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    home = os.path.join(data_dir, "home")
    os.makedirs(os.path.join(home, ".grok"))
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(free_port()), HOME=home,
               CLAUDE_CONFIG_DIR=os.path.join(data_dir, "claude-config"),
               FAKE_CODEX_STATE=os.path.join(data_dir, "codex-state"), FAKE_ACP_STATE=os.path.join(data_dir, "acp-state"))
    os.makedirs(env["CLAUDE_CONFIG_DIR"])
    engine = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(160):
            try:
                if request(port, "GET", "/api/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.25)

        def create(cid, secret):
            status, body = request(port, "POST", "/api/mcp-connectors", {
                "id": cid, "name": cid.capitalize(), "transport": "stdio", "command": sys.executable,
                "args": ["-I", FAKE_MCP, "stdio"], "env": {"FAKE_MCP_SECRET": {"secret": True, "value": secret}}})
            assert status == 201, (status, body)

        create("fake", "abcdef")
        create("altro", "xy")
        _, fleet = request(port, "GET", "/api/bots")
        bot = fleet["bots"][0]
        bot_id, thread_id = bot["id"], bot["threadId"]
        _, instances = request(port, "GET", "/api/instances")
        local = next(i for i in instances["instances"] if i["instanceId"] == instance_id)
        assert local["capabilities"].get("connectors") == "mcp", local["capabilities"]
        model = "claude-sonnet-5" if driver == "claude" else local["models"]["default"] or local["models"]["options"][0]["id"]
        status, body = request(port, "PATCH", f"/api/bots/{bot_id}", {
            "modelSelection": {"instanceId": instance_id, "model": model},
            "connectors": [{"id": "fake", "defaultOn": True}, {"id": "altro", "defaultOn": False}]})
        assert status == 200, (status, body)
        assert request(port, "PATCH", f"/api/bots/{bot_id}", {"connectors": [{"id": "nope"}]})[0] == 400

        def turn(text):
            before = len(request(port, "GET", "/api/bots")[1]["bots"][0].get("messages", []))
            status, body = request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})
            assert status == 202, (status, body)
            deadline = time.time() + 60
            while time.time() < deadline:
                current = request(port, "GET", "/api/bots")[1]["bots"][0]
                replies = [m for m in current.get("messages", [])[before:] if m.get("role") == "bot" and m.get("kind") == "text"]
                if replies and not current.get("busy"):
                    return replies[-1]["text"]
                time.sleep(0.2)
            raise SystemExit(f"{driver}: turn did not settle: {text}")

        results = {}
        reply = turn("CONNETTORE fake ciao")
        assert "ciao (secret len 6)" in reply and "server: fake" in reply, reply
        if driver == "claude":
            assert "mcp__fake" in reply and "mcp__altro" not in reply, reply
        if driver == "codex":
            assert "approval: auto" in reply, reply
        results["default"] = reply

        # this conversation: fake off, altro on
        status, body = request(port, "PATCH", f"/api/bots/{bot_id}/tasks/{thread_id}", {"connectors": {"fake": False, "altro": True}})
        assert status == 200, (status, body)
        reply = turn("CONNETTORE altro due")
        assert "due (secret len 2)" in reply and "server: altro" in reply, reply
        results["switched"] = reply

        # a disabled connector is never mounted, whatever the switches say
        status, body = request(port, "PUT", "/api/mcp-connectors/altro", {
            "name": "Altro", "transport": "stdio", "command": sys.executable, "args": ["-I", FAKE_MCP, "stdio"],
            "env": {"FAKE_MCP_SECRET": {"secret": True}}, "enabled": False})
        assert status == 200, (status, body)
        reply = turn("CONNETTORE altro tre")
        assert "tre" not in reply.split("|")[0] and "altro" not in reply.split("server:")[-1], reply
        results["disabled"] = reply

        # deleting clears the bot's list and the task's switch
        assert request(port, "DELETE", "/api/mcp-connectors/altro")[0] == 200
        current = request(port, "GET", "/api/bots")[1]["bots"][0]
        assert [c["id"] for c in current["connectors"]] == ["fake"], current["connectors"]
        task = next(t for t in current["tasks"] if t["threadId"] == thread_id)
        assert task.get("connectors") == {"fake": False}, task.get("connectors")
        return results
    finally:
        engine.terminate()
        engine.wait(10)
        shutil.rmtree(data_dir, ignore_errors=True)


failed = False
for driver in DRIVERS:
    try:
        results = run(driver)
        print(f"OK   {driver}: {results['default']}")
    except (AssertionError, SystemExit, Exception) as error:  # noqa: BLE001 — report and go on
        failed = True
        print(f"FAIL {driver}: {error!r}")
sys.exit(1 if failed else 0)
