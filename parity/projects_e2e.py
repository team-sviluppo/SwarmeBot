"""Projects end to end on the Swift engine; no model inference or ClickUp access.

  python3 -I parity/projects_e2e.py .build/debug/swarme-harness

The Code/Cylon project routes are Swift plugin APIs, so assertions replace
a comparison with the old Node engine. All files live in a temporary folder.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(binary):
    with tempfile.TemporaryDirectory(prefix="projects-e2e-") as temporary:
        root = Path(temporary)
        port = free_port()
        config = {"instances": {"qa": {"driver": "codex", "config": {
            "cli": str(Path(__file__).resolve().with_name("fake_codex.py"))}}}}
        (root / "config.json").write_text(json.dumps(config))
        env = dict(os.environ, OMB_DATA_DIR=str(root), OMB_PORT=str(port),
                   OMB_WEBHOOK_PORT=str(free_port()), FAKE_CODEX_STATE=str(root / "codex"))
        engine = None

        def request(method, path, body=None, expected=200):
            req = urllib.request.Request(f"http://127.0.0.1:{port}" + path, method=method,
                data=json.dumps(body).encode() if body is not None else None,
                headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=15) as response:
                    code, value = response.status, json.load(response)
            except urllib.error.HTTPError as error:
                code, value = error.code, json.load(error)
            assert code == expected, (path, code, value)
            return value

        def start():
            nonlocal engine
            engine = subprocess.Popen([str(Path(binary).resolve())], env=env,
                stdout=open(root / "engine.log", "a"), stderr=subprocess.STDOUT)
            for _ in range(300):
                if engine.poll() is not None:
                    raise RuntimeError((root / "engine.log").read_text())
                try:
                    return request("GET", "/api/bots")
                except OSError:
                    time.sleep(.1)
            raise RuntimeError("test engine did not start")

        try:
            fleet = start()
            bot = fleet["bots"][0]["id"]
            repos = []
            for index, label in enumerate(["Default", "API", "Web", "Data", "Docs", "Tools", "Mobile"]):
                folder = root / f"repo-{index}"
                folder.mkdir()
                repos.append(dict(role=f"repo-{index}", label=label, path=str(folder),
                                  scripts=[dict(name="Test", command="printf qa")]))
            project = request("POST", "/api/projects", dict(name="Many repos", repos=repos,
                              clickupListId="legacy-list"), expected=201)["project"]
            project_id = project["id"]
            request("PATCH", f"/api/bots/{bot}", {"plugins": {"code": dict(projectId=project_id, role="repo-1")}})
            reordered = list(reversed(repos))
            reordered[-2] = {**reordered[-2], "label": "Public API"}
            changed = request("PATCH", f"/api/projects/{project_id}", dict(repos=reordered))["project"]
            assert [repo["role"] for repo in changed["repos"]] == [repo["role"] for repo in reordered]
            assert changed["repos"][-2]["scripts"][0]["command"] == "printf qa"
            assert request("GET", "/api/bots")["bots"][0]["plugins"]["code"]["role"] == "repo-1"
            request("PATCH", f"/api/projects/{project_id}", dict(repos=[]), expected=409)
            request("POST", "/api/projects", dict(name="Ambiguous", repos=[repos[0], {**repos[1], "label": " default "}]), expected=400)
            route = f"/api/cylon/projects/{project_id}"
            assert request("GET", route)["clickupListId"] == "legacy-list"
            assert request("PUT", route, dict(clickupListId="new-list"))["clickupListId"] == "new-list"
            assert request("PUT", route, dict(clickupListId=None))["clickupListId"] is None
            request("PUT", "/api/plugins/cylon", dict(enabled=False))
            request("GET", route, expected=404)
            assert len(request("GET", "/api/projects")["projects"][0]["repos"]) == 7
            request("PUT", "/api/plugins/cylon", dict(enabled=True))
            exported = json.loads((root / "plugins/code/projects" / (project_id + ".json")).read_text())
            assert "clickupListId" not in exported
            engine.terminate()
            engine.wait(timeout=10)
            engine = None
            start()
            assert request("GET", route)["clickupListId"] is None, "clearing must survive restart and override the legacy value"
            assert request("GET", "/api/projects")["projects"][0]["repos"][-2]["label"] == "Public API"
            print("OK projects: 7 labeled repos, stable assignment, scripts, Cylon migration/toggle/clear, restart")
        finally:
            if engine is not None and engine.poll() is None:
                engine.terminate()
                engine.wait(timeout=10)


if __name__ == "__main__":
    run(sys.argv[1])
