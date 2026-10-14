"""Drive one engine through a scenario and print a normalized trace.

  python3 -I run_scenario.py node|swift <repo-root> <swift-binary>

The trace is what a client would see — SSE frames with ids, timestamps and
sequence numbers stripped — plus the final transcript and every request the
fake endpoint received. Two engines are at parity when their traces match.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ENGINE, REPO, SWIFT_BIN = sys.argv[1], sys.argv[2], sys.argv[3]
DRIVER = os.environ.get("DRIVER", "localEndpoint")
HERE = os.path.dirname(os.path.abspath(__file__))


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
        with urllib.request.urlopen(req, timeout=20) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def raw_request(port, method, path, data, content_type=None):
    """A body that is not JSON (an avatar's bytes, a broken file); the answer is always JSON."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


TEAM_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8" fill="url(#g)"/><use xlink:href="#g"/></svg>"""


def png(width, height):
    """Just enough PNG for the header sniffing that tells a sprite sheet from a photo."""
    import struct
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I4sII", 13, b"IHDR", width, height) + b"\x08\x06\x00\x00\x00"


def team_scenario(port, frames, bot, data_dir, renames):
    """Team files, avatars and cards: every HTTP answer plus every frame they cause."""
    calls = []
    start = len(frames)

    def call(method, path, body=None, raw=None, content_type=None, label=None):
        if raw is not None:
            status, result = raw_request(port, method, path, raw, content_type)
        else:
            status, result = request(port, method, path, body)
        calls.append({"call": label or f"{method} {path}", "status": status, "response": result})
        return status, result

    alfa = bot["id"]
    call("PATCH", f"/api/bots/{alfa}", {"name": "Zoë Ñandú", "title": "Capo", "description": "Guida il lavoro",
                                         "color": "purple", "mascotExpression": "focused", "mascotSilhouette": "hexagon"})
    _, created = request(port, "POST", "/api/bots")
    beta = created["bot"]["id"]
    renames[created["bot"]["name"]] = "<beta-name>"
    call("PATCH", f"/api/bots/{beta}", {"name": "Zoë Ñandú", "color": "cyan"})

    # avatars: markup validated against the allowlist, rasters stored as attachments
    upload = f"/api/bots/{alfa}/avatar/upload"
    call("POST", upload, raw=f'<?xml version="1.0"?>\n{TEAM_SVG}\n'.encode(), content_type="image/svg+xml")
    call("POST", upload, raw=TEAM_SVG.replace("<rect", '<rect onload="alert(1)"').encode(), content_type="image/svg+xml; charset=utf-8")
    call("POST", upload, raw=TEAM_SVG.replace("url(#g)", "url(https://evil.example/x)").encode(), content_type="image/svg+xml")
    call("POST", upload, raw=b"<html></html>", content_type="image/svg+xml")
    call("POST", upload, raw=(TEAM_SVG[:-6] + "x" * 64_000 + "</svg>").encode(), content_type="image/svg+xml", label="POST upload (oversized svg)")
    call("POST", upload, raw=TEAM_SVG.encode(), content_type="text/plain")
    call("POST", upload, raw=TEAM_SVG.encode())
    call("POST", "/api/bots/nobody/avatar/upload", raw=TEAM_SVG.encode(), content_type="image/svg+xml")
    call("POST", f"/api/bots/{beta}/avatar/upload", raw=png(1536, 1872), content_type="image/png")
    call("POST", f"/api/bots/{beta}/avatar/upload", raw=png(512, 512), content_type="IMAGE/PNG")
    call("POST", f"/api/bots/{beta}/avatar/upload", raw=b"", content_type="image/webp")
    call("POST", f"/api/bots/{beta}/avatar/upload", raw=b"x" * (2 * 1024 * 1024 + 1), content_type="image/gif", label="POST upload (oversized gif)")
    call("PATCH", f"/api/bots/{beta}", {"mascotAvatarSheetRow": 9})
    call("PATCH", f"/api/bots/{beta}", {"mascotAvatarSheetRow": 3})
    call("PATCH", f"/api/bots/{beta}", {"mascotAvatarSvg": "<svg></svg>"})
    call("PATCH", f"/api/bots/{beta}", {"mascotAvatarImage": None})
    call("POST", upload, raw=TEAM_SVG.encode(), content_type="image/svg+xml")

    # cards keep their answered/dismissed state
    _, fleet = request(port, "GET", "/api/bots")
    messages = next(b for b in fleet["bots"] if b["id"] == alfa)["messages"]
    card = next(m for m in messages if m.get("card"))
    plain = next(m for m in messages if not m.get("card"))
    call("PATCH", f"/api/bots/{alfa}/cards/{card['id']}", {"answered": "Life admin"})
    call("PATCH", f"/api/bots/{alfa}/cards/{card['id']}", {"dismissed": True, "answered": None, "title": "ignored"})
    call("PATCH", f"/api/bots/{alfa}/cards/{plain['id']}", {"answered": True})
    call("PATCH", f"/api/bots/{alfa}/cards/nothing", {"answered": True})
    call("PATCH", f"/api/bots/nobody/cards/{card['id']}", {"answered": True})

    # export: the visible team, run back through the importer's own limits
    _, exported = call("POST", "/api/teams/export", {})
    call("POST", "/api/teams/export", {"name": "  Squadra Uno  "})
    call("POST", "/api/teams/export", {"name": "x" * 101})

    # the network routes: only the refusals made before any fetch (the library URLs are fixed in Node)
    for body in [{}, {"url": "  "}, {"url": "nope"}, {"url": "http://github.com/a/b"}, {"url": "https://github.com:8443/a/b"},
                 {"url": "https://gitlab.com/a/b"}, {"url": "https://github.com/a/b/blob/main/run.sh"}, {"url": "https://github.com/a%2F../b"}]:
        call("POST", "/api/team-library/github", body)
    call("GET", "/api/team-library/teams/Not_A_Slug")

    # import: refusals first — none of them may create anything
    call("POST", "/api/teams/import?mode=merge", exported)
    call("POST", "/api/teams/import", raw=b"{nope", content_type="application/json")
    for body in [[], {"format": "swarme.team", "version": 99}, {"format": "other", "version": 2, "team": {}},
                 {"format": "swarme.team", "version": 2, "team": {"name": "T", "members": []}},
                 {"format": "swarme.team", "version": 2, "team": {"name": "T", "members": [{"key": "Bad Key", "name": "X", "appearance": {"color": "red"}}]}},
                 {"format": "swarme.team", "version": 1, "team": {"name": "T", "members": [{"key": "a", "name": "A", "appearance": {"color": "red"}}],
                                                                   "room": {"name": "R", "defaultResponder": {"kind": "member", "member": "zz"}}}}]:
        call("POST", "/api/teams/import", body)
    call("POST", "/api/teams/import?mode=project&cwd=relative/dir", exported)
    call("POST", "/api/teams/import?mode=project&cwd=/nonexistent-swarme-parity", exported)

    # add: the export plus a hand-edited member that claims privileges and a hostile picture
    hostile = dict(exported)
    hostile["team"] = dict(exported["team"], description="  Una squadra  ")
    hostile["team"]["members"] = exported["team"]["members"] + [{
        "key": "mole", "name": " zoë ñandú ", "appearance": {"color": "red", "mascotAvatarSvg": TEAM_SVG.replace("<rect", "<script/><rect")},
        "autoApprove": True, "alwaysAllow": ["Bash"], "chiefOfStaff": True, "composio": True, "cwd": "/", "id": alfa,
    }]
    call("POST", "/api/teams/import", hostile)
    # project: a room on a folder, both named by the caller
    project = os.path.join(data_dir, "progetto")
    os.makedirs(project)
    legacy = {"format": "openmaus.team", "version": 1, "team": {"name": "Laboratorio", "members": [
        {"key": "ada", "name": "Ada", "title": " Analista ", "appearance": {"color": "green"}}],
        "room": {"name": "Ignorata", "defaultResponder": {"kind": "everyone"}}}}
    call("POST", f"/api/teams/import?mode=project&cwd={project}/sub/..&room=%20Progetto%20", legacy, label="POST /api/teams/import?mode=project&cwd=<progetto>")
    call("POST", "/api/teams/import?mode=project", legacy)
    # replace: the current team is hidden, the chief of staff released
    call("POST", "/api/teams/import?mode=replace", {"format": "swarme.team", "version": 2, "team": {"name": "Nuova", "members": [
        {"key": "ada", "name": "Ada", "appearance": {"color": "blue"}}]}})
    time.sleep(1)
    _, fleet = request(port, "GET", "/api/bots")
    summary = [{k: b.get(k) for k in ("name", "title", "hidden", "chiefOfStaff", "composio", "color", "mascotAvatarSvg", "modelSelection")}
               for b in fleet["bots"]]
    rooms = [{k: g.get(k) for k in ("name", "memberIds", "cwd", "defaultResponder")} for g in fleet["groups"]]
    # sequence numbers count the streaming frames before this part, chunked differently per engine
    seen = [{k: v for k, v in f.items() if k != "seq"} for f in frames[start:] if f.get("kind") != "hello"]
    return normalize_ids({"calls": calls, "frames": seen, "fleet": summary, "rooms": rooms}, data_dir)


def normalize_ids(value, data_dir):
    """Random ids become <id1>, <id2>… in order of first appearance; timestamps become <ts>."""
    names = {}
    id_keys = {"id", "threadId", "botId", "activeLeafId", "parentId", "memberIds", "mascotAvatarImage", "busyBotId"}

    def walk(node, key=None):
        if isinstance(node, dict):
            return {k: walk(v, k) for k, v in node.items()}
        if isinstance(node, list):
            return [walk(v, key) for v in node]
        if key in id_keys and isinstance(node, str):
            names.setdefault(node, f"<id{len(names) + 1}>")
        if key and (key == "at" or key.endswith("At")) and isinstance(node, (int, float)) and not isinstance(node, bool):
            return "<ts>"
        return node

    text = json.dumps(walk(value), ensure_ascii=False)
    for original, placeholder in sorted(names.items(), key=lambda item: -len(item[0])):
        text = text.replace(original, placeholder)
    return json.loads(text.replace(data_dir, "<data>"))


def request_messages(group):
    return group.get("messages", [])


def main():
    data_dir = tempfile.mkdtemp(prefix=f"parity-{ENGINE}-")
    fake_port, port = free_port(), free_port()
    record = os.path.join(data_dir, "endpoint.ndjson")
    fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_openai.py"), str(fake_port), record])
    computer = os.environ.get("SCENARIO") == "computer"
    box_port, box_record = free_port(), os.path.join(data_dir, "box.ndjson")
    box_fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_box.py"), str(box_port), box_record]) if computer else None
    computer_trace = []
    claude_record = os.path.join(data_dir, "claude.ndjson")
    dsh_port = free_port()
    dsh = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_dsh.py"), str(dsh_port), claude_record]) if DRIVER == "dsh" else None
    settings_trace = []
    instances = {"localEndpoint": {"driver": "localEndpoint"}}
    if DRIVER == "claude":
        instances = {"claude": {"driver": "claudeAgent", "config": {"cli": os.path.join(HERE, "fake_claude.py")}}}
    elif DRIVER == "agy":
        instances = {"agy": {"driver": "antigravityAgent", "config": {"cli": os.path.join(HERE, "fake_agy.py")}}}
    elif DRIVER == "pi":
        instances = {"pi": {"driver": "piAgent", "config": {"cli": os.path.join(HERE, "fake_pi.py")}}}
    elif DRIVER == "codex":
        instances = {"codex": {"driver": "codex", "config": {"cli": os.path.join(HERE, "fake_codex.py")}}}
    elif DRIVER == "dsh":
        instances = {"dsh": {"driver": "deepseekHarness", "config": {"baseUrl": f"http://127.0.0.1:{dsh_port}"}}}
    elif DRIVER == "grok":
        instances = {"grok": {"driver": "grok", "config": {"url": f"http://127.0.0.1:{fake_port}/v1"}}}
    elif DRIVER.startswith("acp:"):
        instances = {"acp": {"driver": DRIVER[4:], "config": {"cli": os.path.join(HERE, "fake_acp.py")}}}
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump({
            "localEndpoint": {"baseUrl": f"http://127.0.0.1:{fake_port}/v1", "apiKey": "test-key"},
            "xai": {"key": "xai-test-key"},
            **({"box": {"token": "box_test-token"}} if computer else {}),
            "instances": instances,
        }, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    webhook_port = free_port()
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(webhook_port), OMB_SKILLS_DIR=os.path.join(REPO, "skills"))
    if computer:
        env.update(OMB_BOX_API=f"http://127.0.0.1:{box_port}/api/box/v1")
        docker_bin = os.path.join(data_dir, "bin")
        os.makedirs(docker_bin)
        docker_path = os.path.join(docker_bin, "docker")
        with open(docker_path, "w") as f:
            f.write(f"#!/bin/sh\nexec {sys.executable} -I {os.path.join(HERE, 'fake_docker.py')} \"$@\"\n")
        os.chmod(docker_path, 0o755)
        env["PATH"] = docker_bin + os.pathsep + env.get("PATH", "")
    if DRIVER == "claude":
        claude_config = os.path.join(data_dir, "claude-config")
        os.makedirs(claude_config)
        # an empty settings dir keeps the user's own ~/.claude out of the catalog;
        # the API key must never reach a subscription CLI
        env.update(CLAUDE_CONFIG_DIR=claude_config, FAKE_CLAUDE_RECORD=claude_record, ANTHROPIC_API_KEY="sk-should-not-leak")
    elif DRIVER == "agy":
        env.update(FAKE_AGY_RECORD=claude_record)
    elif DRIVER == "pi":
        home = os.path.join(data_dir, "home")
        os.makedirs(home)
        env.update(HOME=home, FAKE_PI_RECORD=claude_record, OPENAI_API_KEY="sk-should-not-leak")
    elif DRIVER == "codex":
        home = os.path.join(data_dir, "home")
        os.makedirs(home)
        env.update(HOME=home, FAKE_CODEX_RECORD=claude_record, FAKE_CODEX_STATE=os.path.join(data_dir, "codex-state"),
                   OPENAI_API_KEY="sk-should-not-leak")
    elif DRIVER.startswith("acp:"):
        # a private HOME: the harnesses write their CLI's config there for local models
        home = os.path.join(data_dir, "home")
        os.makedirs(home)
        # the Node engine's grok writer does not create ~/.grok (a signed-in
        # user always has it); without it the send fails before any event
        os.makedirs(os.path.join(home, ".grok"))
        env.update(HOME=home, FAKE_ACP_RECORD=claude_record, FAKE_ACP_STATE=os.path.join(data_dir, "acp-state"),
                   XAI_API_KEY="xai-should-not-leak", OPENAI_API_KEY="sk-should-not-leak")
    if ENGINE == "node":
        cmd = ["node", "--experimental-strip-types", "--no-warnings", os.path.join(REPO, "server", "index.ts")]
    else:
        cmd = [SWIFT_BIN]
    engine = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    frames = []
    renames = {}
    automations = None
    try:
        for _ in range(160):  # boot probes the real CLIs too: give it 40 s
            try:
                if request(port, "GET", "/api/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.25)
        def listen():
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/events?screens=off", timeout=60) as res:
                for raw in res:
                    line = raw.decode().rstrip("\n")
                    if line.startswith("data: "):
                        frames.append(json.loads(line[6:]))
        threading.Thread(target=listen, daemon=True).start()
        time.sleep(0.5)

        _, fleet = request(port, "GET", "/api/bots")
        bot = fleet["bots"][0]
        _, instances = request(port, "GET", "/api/instances")
        instance_id = {"claude": "claude", "grok": "grok", "codex": "codex", "pi": "pi", "agy": "agy", "dsh": "dsh"}.get(DRIVER, "acp" if DRIVER.startswith("acp:") else "localEndpoint")
        local = next(i for i in instances["instances"] if i["instanceId"] == instance_id)
        model = ("claude-sonnet-5" if DRIVER == "claude"
                 else os.environ.get("ACP_MODEL") or local["models"]["default"] or local["models"]["options"][0]["id"] if DRIVER.startswith("acp:") or DRIVER in ("codex", "pi", "agy", "dsh")
                 else local["models"]["options"][0]["id"])
        selection = {"instanceId": instance_id, "model": model}
        if DRIVER == "dsh":
            selection["effort"] = "high"  # must round-trip through session.selectModel
        request(port, "PATCH", f"/api/bots/{bot['id']}", {"modelSelection": selection})

        def turn(text):
            status, _ = request(port, "POST", f"/api/bots/{bot['id']}/messages", {"text": text})
            assert status == 202, status
            deadline = time.time() + 15
            while time.time() < deadline:
                done = [f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"]
                if len(done) >= turn.count and not request(port, "GET", "/api/bots")[1]["bots"][0].get("busy"):
                    return
                time.sleep(0.1)
            raise SystemExit("turn did not settle")
        def settle(count):
            deadline = time.time() + 20
            while time.time() < deadline:
                done = [f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"]
                if len(done) >= count and not request(port, "GET", "/api/bots")[1]["bots"][0].get("busy"):
                    return
                time.sleep(0.1)
            raise SystemExit("turn did not settle")

        turn.count = 1
        turn("Ciao")
        turn.count = 2
        turn("Ancora una volta")
        def answer_card(body, count):
            """Wait for the count-th open card, answer it, wait for the turn."""
            deadline = time.time() + 20
            while time.time() < deadline:
                cards = [f["message"]["card"] for f in frames if f.get("kind") == "message" and f["message"].get("card", {}).get("requestId")]
                if len(cards) >= count:
                    break
                time.sleep(0.1)
            else:
                raise SystemExit("no card")
            status, result = request(port, "POST", f"/api/threads/{bot['threadId']}/respond", {"requestId": cards[count - 1]["requestId"], **body})
            assert status == 200, (status, result)

        if DRIVER.startswith("acp:"):
            bot_id = bot["id"]
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "PERMESSO per favore"})[0] == 202
            answer_card({"behavior": "allow"}, 1)
            settle(3)
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "LENTO"})[0] == 202
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(4)
        if DRIVER == "dsh":
            bot_id = bot["id"]
            send = lambda text: request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})[0] == 202
            assert send("PERMESSO per favore")
            answer_card({"behavior": "allow"}, 1)
            settle(3)
            assert send("DOMANDA per te")
            answer_card({"behavior": "answer", "message": "Blu"}, 2)
            settle(4)
            assert send("LENTO")
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(5)
            time.sleep(1.5)  # the Host's late cancelled turn/end must change nothing
            route = "/api/instances/dsh/deepseek-harness"

            def settings(method, path, body=None, raw=None):
                if raw is not None:
                    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=raw, method=method)
                    req.add_header("Content-Type", "text/plain")
                    try:
                        with urllib.request.urlopen(req, timeout=20) as res:
                            result = (res.status, json.loads(res.read() or b"null"))
                    except urllib.error.HTTPError as e:
                        result = (e.code, json.loads(e.read() or b"null"))
                else:
                    result = request(port, method, path, body)
                settings_trace.append({"call": f"{method} {path.replace(route, '…')}", "body": body, "status": result[0], "response": result[1]})

            settings("GET", route)
            settings("POST", route + "/discover", {"provider": "deepseek"})
            settings("POST", route + "/discover", {"provider": "other"})
            settings("POST", route + "/discover", {})
            settings("PATCH", route, raw=b"{}")
            settings("POST", route + "/upsert", {"provider": "deepseek", "model": {"id": "new-model", "name": "Nuovo", "contextWindow": 64000, "reasoningEfforts": ["off", "high"]}})
            settings("POST", route + "/upsert", {"provider": "deepseek", "model": {"id": "x", "reasoningEfforts": ["high", "off"]}})
            settings("PATCH", route, {"agentPreset": "coding"})
            settings("PATCH", route, {"transport": "paired"})
            settings("PATCH", route, {"baseUrl": "ftp://nope"})
            settings("POST", route + "/pair", {"pairingLink": f"http://127.0.0.1:{dsh_port}/?pair=wrong"})
            settings("POST", route + "/pair", {"pairingLink": f"http://127.0.0.1:{dsh_port}/?pair=tok123"})
            settings("GET", route)
            settings("POST", route + "/discover", {"provider": "deepseek"})
            settings("GET", "/api/nope/deepseek-harness")
            settings("GET", "/api/instances/missing/deepseek-harness")
            # paired transport and a resume from the persisted cursor (the fleet was rebuilt)
            for _ in range(40):
                inst = next(i for i in request(port, "GET", "/api/instances")[1]["instances"] if i["instanceId"] == "dsh")
                if inst["snapshot"]["state"] == "available":
                    break
                time.sleep(0.25)
            assert send("Dopo il pairing")
            settle(6)
        if DRIVER == "agy":
            bot_id = bot["id"]
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "LENTO"})[0] == 202
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(3)
        if DRIVER == "pi":
            bot_id = bot["id"]
            send = lambda text: request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})[0] == 202
            assert send("PERMESSO per favore")
            answer_card({"behavior": "allow"}, 1)
            settle(3)
            assert send("DOMANDA per te")
            answer_card({"behavior": "answer", "message": "Blu"}, 2)
            settle(4)
            assert send("LENTO")
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(5)
        if DRIVER == "codex":
            bot_id = bot["id"]
            send = lambda text: request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})[0] == 202
            assert send("PERMESSO per favore")
            answer_card({"behavior": "allow"}, 1)
            settle(3)
            assert send("VECCHIO stile")
            answer_card({"behavior": "deny"}, 2)
            settle(4)
            assert send("DOMANDA per te")
            answer_card({"behavior": "answer", "message": "Blu"}, 3)
            settle(5)
            assert send("LENTO")
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(6)
        if DRIVER == "claude":
            bot_id = bot["id"]
            # a destructive command: auto mode would stop and ask, so a card shows
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "PERMESSO per favore"})[0] == 202
            answer_card({"behavior": "allow"}, 1)
            settle(3)
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "DOMANDA per te"})[0] == 202
            answer_card({"behavior": "answer", "message": "Blu"}, 2)
            settle(4)
            # interrupt mid-stream: the partial reply is kept, marked interrupted
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "LENTO"})[0] == 202
            time.sleep(1.5)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(5)
        if os.environ.get("SCENARIO") == "automations":
            def quiet(min_completed):
                deadline = time.time() + 40
                seen = -1
                while time.time() < deadline:
                    done = [f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"]
                    _, state = request(port, "GET", "/api/bots")
                    _, rs = request(port, "GET", "/api/routines")
                    idle = not any(b.get("busy") for b in state["bots"]) and not any(r["status"] in ("queued", "running", "waiting") for r in rs["runs"])
                    if len(done) >= min_completed and idle and seen == len(frames):
                        return
                    seen = len(frames)
                    time.sleep(0.4)
                raise SystemExit(f"not quiet: {min_completed}")

            def hook(url, body, headers=None, raw=None):
                data = raw if raw is not None else json.dumps(body).encode()
                req = urllib.request.Request(url, data=data, method="POST")
                req.add_header("Content-Type", "application/json")
                for k, v in (headers or {}).items():
                    req.add_header(k, v)
                try:
                    with urllib.request.urlopen(req, timeout=20) as res:
                        return res.status, json.loads(res.read() or b"null")
                except urllib.error.HTTPError as e:
                    return e.code, json.loads(e.read() or b"null")

            bot_id = bot["id"]
            completed = len([f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"])
            api_log = []
            def call(method, path, body=None):
                status, result = request(port, method, path, body)
                api_log.append({"call": f"{method} {path.split('/')[2]}", "status": status, "error": (result or {}).get("error") if isinstance(result, dict) else None})
                return status, result
            # validation answers the Node way (500 for a routine, 400 for a webhook)
            call("POST", "/api/routines", {"name": "", "prompt": "x", "botId": bot_id, "schedule": {"type": "daily", "time": "07:30"}})
            call("POST", "/api/routines", {"name": "R", "prompt": "x", "botId": bot_id, "schedule": {"type": "daily", "time": "7:30"}})
            call("POST", "/api/webhooks", {"name": "", "prompt": "", "botId": bot_id})
            status, made = call("POST", "/api/routines", {"name": "Mattino", "prompt": "Buongiorno routine", "botId": bot_id,
                                                          "schedule": {"type": "daily", "time": "07:30", "weekdays": [5, 1, 1, 9]}})
            routine_id = made["routine"]["id"]
            status, started = call("POST", f"/api/routines/{routine_id}/run")
            completed += 1
            quiet(completed)
            call("PATCH", f"/api/routines/{routine_id}", {"enabled": False, "durationMinutes": 500})
            # a slow run, cancelled while it runs
            status, slow = call("POST", "/api/routines", {"name": "Lenta", "prompt": "LENTO", "botId": bot_id,
                                                         "schedule": {"type": "once", "at": 4102444800000}})
            status, run = call("POST", f"/api/routines/{slow['routine']['id']}/run")
            time.sleep(1.5)
            call("POST", f"/api/routine-runs/{run['run']['id']}/cancel")
            completed += 1
            quiet(completed)
            call("POST", f"/api/routine-runs/{run['run']['id']}/seen")
            call("POST", f"/api/routine-runs/{run['run']['id']}/cancel")
            # a webhook: bad secret, delivery, duplicate, filtered event, delete
            status, created = call("POST", "/api/webhooks", {"name": "Hook", "prompt": "", "botId": bot_id})
            url = created["credential"]["url"].replace(created["ingress"]["baseUrl"], f"http://127.0.0.1:{webhook_port}")
            endpoint = created["credential"]["endpointUrl"].replace(created["ingress"]["baseUrl"], f"http://127.0.0.1:{webhook_port}")
            api_log.append({"hook": hook(endpoint + "/sbagliato", {"task": "x"})})
            api_log.append({"hook": hook(url, {"task": "fai il punto"}, {"X-GitHub-Event": "push", "Idempotency-Key": "d-1", "User-Agent": "prova/1"})[0]})
            completed += 1
            quiet(completed)
            api_log.append({"hook": hook(url, {"task": "fai il punto"}, {"Idempotency-Key": "d-1"})[0]})
            api_log.append({"hook": hook(url, None, raw=b"{rotto")})
            api_log.append({"hook": hook(endpoint, {"a": 1}, {"Authorization": "Bearer nope"})[0]})
            call("PATCH", f"/api/webhooks/{created['webhook']['id']}", {"eventTypes": ["push", " push ", ""]})
            api_log.append({"hook": hook(url, {"a": 1}, {"X-GitHub-Event": "issues"})[0]})
            call("POST", f"/api/webhooks/{created['webhook']['id']}/rotate")
            api_log.append({"hook": hook(url, {"a": 1})[0]})
            status, final_hooks = call("GET", "/api/webhooks")
            status, final_routines = call("GET", "/api/routines")
            automations = {"api": api_log, "webhooks": final_hooks["webhooks"], "attempts": final_hooks["attempts"],
                           "ingress": sorted(final_hooks["ingress"]), "routines": final_routines["routines"], "runs": final_routines["runs"]}
            call("DELETE", f"/api/webhooks/{created['webhook']['id']}")
            call("DELETE", f"/api/routines/{routine_id}")
        if computer:
            import hashlib, re
            bot_id = bot["id"]
            # the box name derives from the bot id, the bootstrap from its name
            request(port, "PATCH", f"/api/bots/{bot_id}", {"name": "Robo"})
            box_name = "ogb-" + re.sub(r"[^a-z0-9]", "", bot_id[:8].lower()) + "-" + hashlib.sha256(bot_id.encode()).hexdigest()[:6]
            renames[box_name] = "<box-name>"
            def call(method, path, body=None):
                status, out = request(port, method, f"/api/bots/{bot_id}/computer{path}", body)
                if isinstance(out, dict) and isinstance(out.get("heldSinceMs"), (int, float)):
                    out["heldSinceMs"] = "<ms>"
                computer_trace.append({"call": f"{method} {path}", "status": status, "out": out})
            call("GET", "")
            call("POST", "/provision", {})
            call("GET", "")
            call("POST", "/exec", {"command": "echo ciao"})
            call("POST", "/screenshot", {})
            call("POST", "/join", {})
            call("POST", "/sleep", {})
            call("GET", "")
            call("POST", "/remove", {})
            call("POST", "/provision", {})  # an archived box is woken, not recreated
            call("GET", "/control")
            call("POST", "/control", {"action": "take"})
            call("POST", "/control", {"action": "take"})
            call("POST", "/control", {"action": "dismiss-help"})
            call("POST", "/control", {"action": "release"})
            call("POST", "/control", {"action": "nope"})
            computer_trace.append({"bots.computerControl": request(port, "GET", "/api/bots")[1]["computerControl"][bot_id]})
            time.sleep(0.5)
            if DRIVER == "claude":
                def scrub_vm(value):
                    if isinstance(value, str):
                        return value.replace(data_dir, "<data>")
                    if isinstance(value, list):
                        return [scrub_vm(item) for item in value]
                    if isinstance(value, dict):
                        return {key: scrub_vm(item) for key, item in value.items()}
                    return value
                status, vm = request(port, "GET", "/api/local-computer")
                computer_trace.append({"call": "GET /api/local-computer", "status": status, "out": scrub_vm(vm)})
                assert request(port, "PATCH", f"/api/bots/{bot_id}", {"computer": "vm"})[0] == 200
                done = lambda: [f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"]
                before = len(done())
                assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "COMPUTER"})[0] == 202
                deadline = time.time() + 40
                while time.time() < deadline and len(done()) <= before:
                    time.sleep(0.2)
                if len(done()) <= before:
                    raise SystemExit("local VM turn did not finish")
        if os.environ.get("SCENARIO") == "rooms":
            def idle(min_completed):
                """Every bot and room quiet, and no new frame for a moment."""
                deadline = time.time() + 40
                seen = -1
                while time.time() < deadline:
                    done = [f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"]
                    _, state = request(port, "GET", "/api/bots")
                    quiet = not any(b.get("busy") for b in state["bots"]) and not any(g.get("busyBotId") for g in state["groups"])
                    if len(done) >= min_completed and quiet and seen == len(frames):
                        return
                    seen = len(frames)
                    time.sleep(0.4)
                raise SystemExit(f"not idle: {min_completed}")
            alfa = bot["id"]
            status, created = request(port, "POST", "/api/bots")
            beta = created["bot"]["id"]
            renames.update({created["bot"]["name"]: "<beta-name>", alfa: "<alfa>", beta: "<beta>"})
            request(port, "PATCH", f"/api/bots/{alfa}", {"name": "Alfa"})
            request(port, "PATCH", f"/api/bots/{beta}", {"name": "Beta", "modelSelection": {"instanceId": instance_id, "model": model}})
            completed = len([f for f in frames if f.get("kind") == "runtime" and f["event"]["type"] == "turn.completed"])
            say = lambda bot_id, text: request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})[0] == 202
            # ask_bot: Alfa's turn runs a Beta turn inside it and gets the reply back
            assert say(alfa, "CHIEDI Beta: come va?")
            completed += 2
            idle(completed)
            # delegate_bot: Beta runs after Alfa's turn settles
            assert say(alfa, "DELEGA Beta: prepara il riepilogo")
            completed += 2
            idle(completed)
            # approvePeerComms: a card in Alfa's thread, allowed by the user
            request(port, "PATCH", f"/api/bots/{alfa}", {"approvePeerComms": True})
            assert say(alfa, "CHIEDI Beta: sei libero?")
            deadline = time.time() + 20
            while time.time() < deadline:
                cards = [f["message"]["card"] for f in frames if f.get("kind") == "message"
                         and f["message"].get("card", {}).get("tool") == "ask_bot"]
                if cards:
                    break
                time.sleep(0.1)
            status, answered = request(port, "POST", f"/api/bots/{alfa}/respond", {"requestId": cards[0]["requestId"], "behavior": "allow"})
            assert status == 200 and answered["outcome"] == "allowed-once", answered
            completed += 2
            idle(completed)
            # a room: default responder, an @mention, a one-hop chain
            status, room = request(port, "POST", "/api/groups", {"name": "Stanza", "memberIds": [alfa, beta]})
            assert status in (200, 201), (status, room)
            room_id = room["group"]["id"]
            for text, turns in [("Ciao a tutti", 1), ("@Beta tocca a te", 1), ("CATENA per favore", 2)]:
                assert request(port, "POST", f"/api/groups/{room_id}/messages", {"text": text})[0] == 202
                completed += turns
                idle(completed)
        team_trace = team_scenario(port, frames, bot, data_dir, renames) if os.environ.get("SCENARIO") == "team" else None
        if os.environ.get("SCENARIO") == "advanced":
            bot_id = bot["id"]
            _, now = request(port, "GET", "/api/bots")
            first_user = next(m for m in now["bots"][0]["messages"] if m["role"] == "user")
            # edit → a new branch and a new turn
            assert request(port, "POST", f"/api/bots/{bot_id}/messages/{first_user['id']}/edit", {"text": "Ciao, versione due"})[0] == 202
            settle(3)
            # back to the first version (no turn)
            assert request(port, "POST", f"/api/bots/{bot_id}/active-branch", {"messageId": first_user["id"]})[0] == 200
            # a slow turn, a message queued behind it, drained on settle
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "LENTO uno"})[0] == 202
            time.sleep(0.4)
            status, queued = request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "in coda"})
            assert status == 202 and queued.get("queued"), queued
            settle(5)
            # interrupt mid-stream: the partial reply is kept, marked interrupted
            assert request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": "LENTO due"})[0] == 202
            time.sleep(1.2)
            assert request(port, "POST", f"/api/bots/{bot_id}/interrupt")[0] == 200
            settle(6)
        time.sleep(0.5)
        _, final = request(port, "GET", "/api/bots")
    finally:
        engine.terminate()
        fake.terminate()
        if box_fake:
            box_fake.terminate()
        if dsh:
            dsh.terminate()
        engine.wait(5)

    def norm_message(m):
        out = {"role": m["role"], "kind": m["kind"]}
        for key in ("text", "queued", "interrupted"):
            if key in m:
                out[key] = m[key]
        if "from" in m:
            out["from"] = m["from"].get("name")
        if "comm" in m:
            out["comm"] = m["comm"].get("withName")
        if "tool" in m:
            out["tool"] = {k: v for k, v in m["tool"].items() if k != "spoken"}
        if "card" in m:
            out["card"] = {k: m["card"][k] for k in ("title", "subtitle", "options", "tool", "allowKey", "held", "answered", "dismissed") if k in m["card"]}
        return out

    def scrub(value):
        """Ids, times and secrets differ by construction: keep the shape."""
        if isinstance(value, dict):
            out = {}
            for k, v in value.items():
                if k in ("id", "routineId", "webhookId", "runId", "lastRunId", "threadId", "botId", "endpointId", "secret", "url", "endpointUrl") and v:
                    out[k] = "<id>"
                elif (k.endswith("At") or k in ("scheduledFor", "nextRunAt")) and isinstance(v, (int, float)):
                    out[k] = "<t>"
                elif k == "deliveryId" and isinstance(v, str) and not v.startswith("d-"):
                    out[k] = "<id>"
                else:
                    out[k] = scrub(v)
            return out
        if isinstance(value, list):
            return [scrub(v) for v in value]
        return value

    def norm(frame):
        kind = frame["kind"]
        if kind == "runtime":
            e = frame["event"]
            out = {"kind": kind, "type": e["type"]}
            for key in ("streamKind", "delta", "itemType", "text", "ok", "stopReason", "input", "output", "message",
                        "cost", "usage", "requestType", "tool", "summary", "choices", "behavior", "source", "title", "tokens"):
                if key in e:
                    out[key] = e[key]
            return out
        if kind in ("message", "message.patch"):
            return {"kind": kind, "message": norm_message(frame["message"])}
        if kind == "bot":
            b = frame["bot"]
            return {"kind": kind, "activity": b.get("activity"), "busy": b.get("busy"), "unread": b.get("unread"),
                    "tasks": [t["title"] for t in b.get("tasks", [])],
                    "usage": [t.get("usage") for t in b.get("tasks", [])]}
        if kind == "notify":
            n = frame["notification"]
            return {"kind": kind, "title": n["title"], "body": n["body"]}
        if kind in ("routine", "routine.run", "webhook", "webhook.attempt"):
            return {"kind": kind, kind.split(".")[-1]: scrub(next(v for k, v in frame.items() if k not in ("kind", "seq")))}
        return {"kind": kind}

    sent = []
    for path in (record, claude_record, box_record):
        if os.path.exists(path):
            with open(path) as f:
                sent += [json.loads(line) for line in f]
    normalized = []
    for f in frames:
        if f.get("kind") == "hello":
            continue
        n = norm(f)
        if n.get("type") == "content.delta":
            n.pop("delta", None)
            if normalized and normalized[-1] == n:
                continue
        if isinstance(n.get("message"), dict) and n["message"].get("interrupted"):
            n["message"].pop("text", None)
        if n.get("type") == "turn.completed" and n.get("stopReason") == "interrupted":
            pass
        normalized.append(n)
    for m in final["bots"][0]["messages"]:
        if m.get("interrupted"):
            m.pop("text", None)
    written = {}
    home = os.path.join(data_dir, "home")
    for root, _, files in os.walk(home):
        if "/Library/Caches" in root or "/.cursor" in root:
            continue  # the real cursor-agent, probed at boot, writes these
        for name in files:
            path = os.path.join(root, name)
            try:
                with open(path) as f:
                    written[os.path.relpath(path, home)] = f.read().replace(data_dir, "<data>")
            except UnicodeDecodeError:
                written[os.path.relpath(path, home)] = "<binary>"
    if DRIVER == "dsh":
        # concurrent calls (llm.providers ∥ settings.describe) land in either order
        sent.sort(key=lambda entry: json.dumps(entry, sort_keys=True))
    if os.environ.get("SCENARIO") == "rooms":
        final_bots = {b["name"]: [norm_message(m) for m in b["messages"]] for b in final["bots"]}
        final_rooms = {g["name"]: [norm_message(m) for m in request_messages(g)] for g in final["groups"]}
    else:
        final_bots = final_rooms = None
    trace = {
        "automations": scrub(automations),
        "computer": computer_trace,
        "settings": settings_trace,
        "team": team_trace,
        "bots": final_bots,
        "rooms": final_rooms,
        "written": written,
        "frames": normalized,
        "transcript": [norm_message(m) for m in final["bots"][0]["messages"]],
        "endpoint": sent,
        "models": [o["id"] for o in local["models"]["options"]],
    }
    # bot names are picked at random: the only legitimately different value
    text = json.dumps(trace, indent=1, ensure_ascii=False).replace(bot["name"], "<bot>")
    for original, placeholder in renames.items():
        text = text.replace(original, placeholder)
    text = text.replace(f"127.0.0.1:{fake_port}", "127.0.0.1:<fake>")
    import re
    text = re.sub(r"\d{4}-\d\d-\d\dT[\d:.]+Z", "<iso>", text).replace(f"127.0.0.1:{dsh_port}", "127.0.0.1:<dsh>")
    print(text)
    shutil.rmtree(data_dir, ignore_errors=True)


main()
