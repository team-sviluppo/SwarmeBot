"""Connectors end to end on the Swift engine (docs/plans/2026-10-15-connettori-mcp.md §10).

  python3 -I connectors_e2e.py <swift-binary> [claude|codex|acp:<driverKind>|localEndpoint|oauth ...]

For each engine: a bot gets two connectors (both `fake_mcp.py stdio`), one on
by default and one off; a turn calls `echo` through the real proxy and pool;
the conversation's switches flip which one is mounted; deleting a connector
clears it from the bot and the task. The Local Endpoint runs the tool loop
itself against `fake_openai.py` (phase 3): one call, two in parallel, the
round limit, a model that refuses tools and a Hermes model that never gets
them. `oauth` logs an HTTP connector in through `fake_mcp.py`'s authorization
server (phase 4): discovery, dynamic registration, PKCE, the browser's
round trip to the engine's callback, refresh on expiry, a revoked refresh
token, logout. Assertions, not a trace: the Node engine
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
DRIVERS = sys.argv[2:] or ["claude", "codex", "acp:geminiAgent", "acp:kimiAgent", "localEndpoint", "oauth"]
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


def run_local():
    data_dir = tempfile.mkdtemp(prefix="conn-e2e-le-")
    port, fake_port = free_port(), free_port()
    record = os.path.join(data_dir, "endpoint.ndjson")
    fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_openai.py"), str(fake_port), record],
                            env={**os.environ, "FAKE_OPENAI_HERMES": "1"})
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump({"localEndpoint": {"baseUrl": f"http://127.0.0.1:{fake_port}/v1", "apiKey": "test-key"},
                   "instances": {"localEndpoint": {"driver": "localEndpoint"}}}, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(free_port()))
    engine = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(160):
            try:
                if request(port, "GET", "/api/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.25)
        status, body = request(port, "POST", "/api/mcp-connectors", {
            "id": "fake", "name": "Fake", "transport": "stdio", "command": sys.executable,
            "args": ["-I", FAKE_MCP, "stdio"], "env": {"FAKE_MCP_SECRET": {"secret": True, "value": "abcdef"}}})
        assert status == 201, (status, body)
        _, instances = request(port, "GET", "/api/instances")
        local = next(i for i in instances["instances"] if i["instanceId"] == "localEndpoint")
        assert local["capabilities"]["connectors"] == "inline", local["capabilities"]
        options = {o["id"]: o for o in local["models"]["options"]}
        hermes_id = next(i for i in options if i.endswith("fake/hermes-1"))
        assert options[hermes_id].get("clientTools") is False, options[hermes_id]
        echo_id = next(i for i in options if i.endswith("fake/echo-1"))
        assert "clientTools" not in options[echo_id], options[echo_id]
        no_tools_id = next(i for i in options if i.endswith("fake/no-tools"))
        _, fleet = request(port, "GET", "/api/bots")
        bot = fleet["bots"][0]
        bot_id, thread_id = bot["id"], bot["threadId"]

        def use(model):
            status, body = request(port, "PATCH", f"/api/bots/{bot_id}", {
                "modelSelection": {"instanceId": "localEndpoint", "model": model}, "connectors": [{"id": "fake", "defaultOn": True}]})
            assert status == 200, (status, body)

        def requests_since(mark):
            with open(record) as f:
                return [json.loads(line) for line in f.readlines()[mark:]]

        def mark():
            try:
                with open(record) as f:
                    return len(f.readlines())
            except FileNotFoundError:
                return 0

        def turn(text):
            before = len(request(port, "GET", "/api/bots")[1]["bots"][0].get("messages", []))
            status, body = request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})
            assert status == 202, (status, body)
            deadline = time.time() + 60
            while time.time() < deadline:
                current = request(port, "GET", "/api/bots")[1]["bots"][0]
                fresh = current.get("messages", [])[before:]
                replies = [m for m in fresh if m.get("role") == "bot" and m.get("kind") == "text"]
                if replies and not current.get("busy"):
                    chips = [m["tool"] for m in fresh if m.get("kind") == "activity" and m.get("tool")]
                    return replies[-1]["text"], chips
                time.sleep(0.2)
            raise SystemExit(f"localEndpoint: turn did not settle: {text}")

        use(echo_id)
        at = mark()
        reply, chips = turn("STRUMENTO echo ciao")
        assert reply == "Risultato: ciao (secret len 6)", reply
        assert [(c["name"], c["ok"]) for c in chips] == [("Fake · echo", True)], chips
        # what the call was asked and answered, for the transcript's details
        assert json.loads(chips[0]["input"]) == {"text": "ciao"} and chips[0]["output"] == "ciao (secret len 6)", chips
        sent = requests_since(at)
        assert len(sent) == 2 and sent[0]["tools"][0] == "fake__echo" and sent[1]["roles"][-2:] == ["assistant", "tool"], sent
        first = reply

        reply, chips = turn("DOPPIO echo uno due")
        assert reply == "Ne chiamo due.\n\nRisultato: uno (secret len 6) / due (secret len 6)", reply
        assert [c["name"] for c in chips] == ["Fake · echo", "Fake · echo"] and all(c["ok"] for c in chips), chips

        at = mark()
        reply, chips = turn("CICLO echo")
        sent = requests_since(at)
        assert len(sent) == 21 and "tools" not in sent[-1], [len(sent), sent[-1]]
        assert any("Limite di 20" in c["name"] for c in chips), chips

        # this chat switches the connector off: no tools go out
        assert request(port, "PATCH", f"/api/bots/{bot_id}/tasks/{thread_id}", {"connectors": {"fake": False}})[0] == 200
        at = mark()
        reply, _ = turn("STRUMENTO echo spento")
        assert all("tools" not in r for r in requests_since(at)), requests_since(at)
        assert request(port, "PATCH", f"/api/bots/{bot_id}/tasks/{thread_id}", {"connectors": {}})[0] == 200

        # a model without function calling: 400, then the same turn without tools
        use(no_tools_id)
        at = mark()
        reply, chips = turn("STRUMENTO echo niente")
        sent = requests_since(at)
        assert [("tools" in r) for r in sent] == [True, False], sent
        assert any("non accetta strumenti" in c["name"] for c in chips), chips
        at = mark()
        turn("STRUMENTO echo ancora")
        assert all("tools" not in r for r in requests_since(at)), "remembered until the catalog is read again"

        # a Hermes profile runs its own tools: ours never go out
        use(hermes_id)
        at = mark()
        reply, _ = turn("STRUMENTO echo hermes")
        assert all("tools" not in r for r in requests_since(at)), requests_since(at)
        return {"default": first}
    finally:
        engine.terminate()
        engine.wait(10)
        fake.terminate()
        shutil.rmtree(data_dir, ignore_errors=True)


def run_oauth():
    data_dir = tempfile.mkdtemp(prefix="conn-e2e-oauth-")
    port, mcp_port, llm_port = free_port(), free_port(), free_port()
    fake = subprocess.Popen([sys.executable, "-I", FAKE_MCP, "http", str(mcp_port)],
                            env={**os.environ, "FAKE_MCP_OAUTH": "1", "FAKE_MCP_TOKEN_TTL": "3"})
    llm = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_openai.py"), str(llm_port), os.path.join(data_dir, "llm.ndjson")])
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump({"localEndpoint": {"baseUrl": f"http://127.0.0.1:{llm_port}/v1", "apiKey": "test-key"},
                   "instances": {"localEndpoint": {"driver": "localEndpoint"}}}, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(free_port()))
    engine = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(160):
            try:
                if request(port, "GET", "/api/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.25)
        mcp = f"http://127.0.0.1:{mcp_port}"

        def stats():
            with urllib.request.urlopen(mcp + "/control/stats") as res:
                return json.loads(res.read())

        def connector():
            return request(port, "GET", "/api/mcp-connectors/web")[1]["connector"]

        def test():
            return request(port, "POST", "/api/mcp-connectors/web/test")[1]["connector"]

        status, body = request(port, "POST", "/api/mcp-connectors", {"id": "web", "name": "Web", "transport": "http",
                                                                      "url": mcp + "/mcp", "auth": "oauth"})
        assert status == 201, (status, body)
        assert body["connector"]["oauthState"]["status"] == "disconnected", body
        assert request(port, "POST", "/api/mcp-connectors", {"id": "bad", "transport": "stdio", "command": "x", "auth": "oauth"})[0] == 400
        check = test()["lastCheck"]
        assert check["ok"] is False and "Accedi" in check["error"], check

        # the login: what the browser does, followed by hand
        status, body = request(port, "POST", "/api/mcp-connectors/web/oauth/start")
        assert status == 200, (status, body)
        assert body["redirectUri"] == f"http://127.0.0.1:{port}/oauth/mcp/callback", body
        try:
            with urllib.request.urlopen(body["authorizationUrl"]) as res:
                page = res.read().decode()
                assert res.status == 200 and "Fatto" in page, page
        except urllib.error.HTTPError as error:
            raise AssertionError(f"login: {error.url} {error.read()[-300:]!r}")
        current = connector()
        assert current["oauthState"]["status"] == "connected", current
        assert current["lastCheck"]["ok"] is True and len(current["lastCheck"]["tools"]) == 7, current["lastCheck"]
        assert current["oauthClient"]["clientId"] == "client-1", current.get("oauthClient")
        assert stats() == {"authorization_code": 1, "refresh_token": 0, "register": 1}, stats()
        secrets = open(os.path.join(data_dir, "mcp-connector-secrets.json")).read()
        assert "at-" in secrets and "at-" not in json.dumps(current) and "at-" not in open(os.path.join(data_dir, "mcp-connectors.json")).read()

        # a bot's turn goes through the pool with the same token
        _, fleet = request(port, "GET", "/api/bots")
        bot_id = fleet["bots"][0]["id"]
        _, instances = request(port, "GET", "/api/instances")
        local = next(i for i in instances["instances"] if i["instanceId"] == "localEndpoint")
        model = next(o["id"] for o in local["models"]["options"] if o["id"].endswith("fake/echo-1"))
        assert request(port, "PATCH", f"/api/bots/{bot_id}", {"modelSelection": {"instanceId": "localEndpoint", "model": model},
                                                               "connectors": [{"id": "web", "defaultOn": True}]})[0] == 200

        def turn(text):
            before = len(request(port, "GET", "/api/bots")[1]["bots"][0].get("messages", []))
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})[0] == 202
            deadline = time.time() + 60
            while time.time() < deadline:
                current = request(port, "GET", "/api/bots")[1]["bots"][0]
                replies = [m for m in current.get("messages", [])[before:] if m.get("role") == "bot" and m.get("kind") == "text"]
                if replies and not current.get("busy"):
                    return replies[-1]["text"]
                time.sleep(0.2)
            raise SystemExit(f"oauth: turn did not settle: {text}")

        reply = turn("STRUMENTO headers")
        # the token reached the server; the transcript keeps only its shape
        assert reply.startswith("Risultato: ") and '"Authorization": "Bearer «redacted' in reply and "at-" not in reply, reply

        # the access token lives 3 s: the next use refreshes it
        time.sleep(3.5)
        assert test()["lastCheck"]["ok"] is True
        assert stats()["refresh_token"] == 1, stats()
        time.sleep(3.5)
        reply = turn("STRUMENTO echo dopo")
        assert reply == "Risultato: dopo (secret len 0)", reply
        assert stats()["refresh_token"] == 2, stats()

        # a second login reuses the registered client
        status, body = request(port, "POST", "/api/mcp-connectors/web/oauth/start")
        try:
            with urllib.request.urlopen(body["authorizationUrl"]) as res:
                assert res.status == 200
        except urllib.error.HTTPError as error:
            raise AssertionError(f"second login: {error.url} {error.read()[:300]!r}")
        assert stats()["register"] == 1, stats()

        # the server forgets every token: the refresh is refused, the login is gone
        urllib.request.urlopen(urllib.request.Request(mcp + "/control/revoke", data=b"{}", method="POST")).read()
        check = test()["lastCheck"]
        assert check["ok"] is False and "scaduto" in check["error"], check
        assert connector()["oauthState"]["status"] == "disconnected", connector()

        # a stale callback is refused; logout clears what is left
        stale = urllib.request.Request(f"http://127.0.0.1:{port}/oauth/mcp/callback?code=x&state=nope")
        try:
            urllib.request.urlopen(stale)
            raise AssertionError("a callback with an unknown state must fail")
        except urllib.error.HTTPError as error:
            assert error.code == 400
        status, body = request(port, "POST", "/api/mcp-connectors/web/oauth/logout")
        assert status == 200 and body["connector"]["oauthState"]["status"] == "disconnected", body
        return {"default": "login, refresh, revoke, logout"}
    finally:
        engine.terminate()
        engine.wait(10)
        fake.terminate()
        llm.terminate()
        shutil.rmtree(data_dir, ignore_errors=True)


failed = False
for driver in DRIVERS:
    try:
        results = run_local() if driver == "localEndpoint" else run_oauth() if driver == "oauth" else run(driver)
        print(f"OK   {driver}: {results['default']}")
    except (AssertionError, SystemExit, Exception) as error:  # noqa: BLE001 — report and go on
        failed = True
        print(f"FAIL {driver}: {error!r}")
        import traceback
        traceback.print_exc(limit=3)
sys.exit(1 if failed else 0)
