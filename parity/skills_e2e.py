"""Skills end to end on the Swift engine (docs/plans/2026-10-21-skill.md).

  python3 -I skills_e2e.py <swift-binary> [claude] [localEndpoint]

For each engine: a skill with a `scripts/` subfolder is imported through the
API; a bot gets it off by default and a second one on; the turn's system
prompt carries the index of the skills switched on (paths for Claude, the
whole text for the Local Endpoint); the chat's switch adds the first;
`/name` puts the skill's whole text into the turn while the stored message
stays as typed; a shared folder chosen in Settings shows the skills already
in it; deleting a skill clears it from the bot and the chat. Assertions,
not a trace: the Node engine never had these skills.
"""
import base64
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
DRIVERS = sys.argv[2:] or ["claude", "localEndpoint"]
HERE = os.path.dirname(os.path.abspath(__file__))

REPORT = """---
name: meta-report
description: >
  Builds the weekly Meta ads report
  as a table.
---

Run scripts/fetch.py, then fill the table with campaign, spend and results.
"""
TONE = """---
name: tone
description: Answers in a friendly tone.
---

Always greet the user first.
"""


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


def files(*entries):
    return [{"path": p, "content": base64.b64encode(t.encode()).decode(), "executable": x} for p, t, x in entries]


def run(driver):
    data_dir = tempfile.mkdtemp(prefix="skills-e2e-")
    port = free_port()
    record = os.path.join(data_dir, "record.ndjson")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    fake = None
    if driver == "claude":
        config = {"instances": {"claude": {"driver": "claudeAgent", "config": {"cli": os.path.join(HERE, "fake_claude.py")}}}}
        os.makedirs(os.path.join(data_dir, "claude-config"))
        env.update(CLAUDE_CONFIG_DIR=os.path.join(data_dir, "claude-config"), FAKE_CLAUDE_RECORD=record, FAKE_CLAUDE_RECORD_SYSTEM="1")
        instance_id, model = "claude", "claude-sonnet-5"
    else:
        fake_port = free_port()
        fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_openai.py"), str(fake_port), record],
                                env={**os.environ, "FAKE_OPENAI_RECORD_SYSTEM": "1"})
        config = {"localEndpoint": {"baseUrl": f"http://127.0.0.1:{fake_port}/v1", "apiKey": "test-key"},
                  "instances": {"localEndpoint": {"driver": "localEndpoint"}}}
        instance_id, model = "localEndpoint", None
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump(config, f)
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(free_port()))
    engine = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(160):
            try:
                if request(port, "GET", "/api/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.25)

        status, body = request(port, "POST", "/api/skills", {"files": files(
            ("SKILL.md", REPORT, False), ("scripts/fetch.py", "print('campaigns')\n", True), ("references/fields.md", "# Fields\n", False))})
        assert status == 201, (status, body)
        assert body["skill"]["files"] == ["SKILL.md", "references/fields.md", "scripts/fetch.py"], body
        assert body["skill"]["description"] == "Builds the weekly Meta ads report as a table.", body
        assert os.access(os.path.join(data_dir, "skills", "meta-report", "scripts", "fetch.py"), os.X_OK)
        assert request(port, "POST", "/api/skills", {"files": files(("SKILL.md", TONE, False))})[0] == 201

        _, instances = request(port, "GET", "/api/instances")
        local = next(i for i in instances["instances"] if i["instanceId"] == instance_id)
        model = model or next(o["id"] for o in local["models"]["options"] if o["id"].endswith("fake/echo-1"))
        bot = request(port, "GET", "/api/bots")[1]["bots"][0]
        bot_id, thread_id = bot["id"], bot["threadId"]
        status, body = request(port, "PATCH", f"/api/bots/{bot_id}", {
            "modelSelection": {"instanceId": instance_id, "model": model},
            "skills": [{"id": "meta-report", "defaultOn": False}, {"id": "tone", "defaultOn": True}]})
        assert status == 200, (status, body)

        def turn(text):
            before = len(request(port, "GET", "/api/bots")[1]["bots"][0].get("messages", []))
            status, body = request(port, "POST", f"/api/bots/{bot_id}/messages", {"text": text})
            assert status == 202, (status, body)
            deadline = time.time() + 60
            while time.time() < deadline:
                current = request(port, "GET", "/api/bots")[1]["bots"][0]
                messages = current.get("messages", [])[before:]
                if any(m.get("role") == "bot" and m.get("kind") == "text" for m in messages) and not current.get("busy"):
                    with open(record) as f:
                        sent = json.loads(f.readlines()[-1])
                    system = sent.get("systemPrompt") if driver == "claude" else sent.get("system")
                    prompt = sent.get("prompt") if driver == "claude" else sent.get("last")
                    user = next(m["text"] for m in messages if m.get("role") == "user")
                    return system or "", prompt or "", user
                time.sleep(0.2)
            raise SystemExit(f"{driver}: turn did not settle: {text}")

        results = {}
        system, prompt, _ = turn("ciao")
        assert "tone" in system and "meta-report" not in system, system
        if driver == "claude":
            assert os.path.join(data_dir, "skills", "tone", "SKILL.md") in system, system
            assert "Always greet the user first." not in system, "the index carries no instructions"
        else:
            assert "Always greet the user first." in system, "an engine without files gets the text"
            assert data_dir not in system, system
        results["default"] = "tone only"

        assert request(port, "PATCH", f"/api/bots/{bot_id}/tasks/{thread_id}", {"skills": {"meta-report": True}})[0] == 200
        system, _, _ = turn("e ora?")
        listed = "meta-report: Builds the weekly Meta ads report as a table." if driver == "claude" else '<skill name="meta-report">'
        assert listed in system, system
        results["switched"] = "both"

        assert request(port, "PATCH", f"/api/bots/{bot_id}/tasks/{thread_id}", {"skills": {}})[0] == 200
        system, prompt, user = turn("/meta-report per ottobre")
        assert "Run scripts/fetch.py" in prompt and prompt.rstrip().endswith("/meta-report per ottobre"), prompt
        assert prompt.startswith("[The user called /meta-report"), prompt
        assert (os.path.join(data_dir, "skills", "meta-report") in prompt) == (driver == "claude"), prompt
        assert "meta-report" not in system, "an off skill is called, not listed"
        assert user == "/meta-report per ottobre", user
        results["called"] = "whole text in the turn"

        # a shared folder: what is already there shows up, and turns read it
        shared = os.path.join(data_dir, "OneDrive", "Skill")
        os.makedirs(os.path.join(shared, "tone"))
        with open(os.path.join(shared, "tone", "SKILL.md"), "w") as f:
            f.write(TONE.replace("friendly", "formal"))
        status, body = request(port, "PUT", "/api/skills-folder", {"folder": shared})
        assert status == 200 and body["custom"] is True, (status, body)
        listed = request(port, "GET", "/api/skills")[1]["skills"]
        assert [s["id"] for s in listed] == ["tone"] and "formal" in listed[0]["description"], listed
        system, _, _ = turn("di nuovo")
        assert "formal" in system and "meta-report" not in system, system
        assert request(port, "PUT", "/api/skills-folder", {"folder": None})[1]["custom"] is False
        results["shared folder"] = "read in place"

        assert request(port, "DELETE", "/api/skills/meta-report")[0] == 200
        current = request(port, "GET", "/api/bots")[1]["bots"][0]
        assert [s["id"] for s in current["skills"]] == ["tone"], current["skills"]
        return results
    finally:
        engine.terminate()
        engine.wait(10)
        if fake:
            fake.terminate()
        shutil.rmtree(data_dir, ignore_errors=True)


for driver in DRIVERS:
    print(driver, json.dumps(run(driver)))
print("skills e2e: ok")
