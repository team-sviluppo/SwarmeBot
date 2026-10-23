"""Mixed channels end to end on the Swift engine (Sources/HarnessCore/MixedRooms.swift).

  python3 -I mixed_rooms_e2e.py <swift-binary>

Two engines on the fake OpenAI endpoint: a host with Alfa and a guest with
Beta. The host learns of the guest (`PUT /api/peer-engines`), makes a room
with Alfa and Beta as a guest, and `@everyone` gets both replies: Alfa's on
the host, Beta's from the guest engine, whose prompt carries the host's
conversation (Alfa's reply included). On the guest a mirror room holds the
conversation once (a second round adds only what is new), refuses messages
of its own and is not unread. Assertions, not a trace: the Node engine never
had mixed channels.
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
        with urllib.request.urlopen(req, timeout=60) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def start(fake_port, name):
    data_dir = tempfile.mkdtemp(prefix=f"mixed-{name}-")
    port = free_port()
    with open(os.path.join(data_dir, "config.json"), "w") as f:
        json.dump({"localEndpoint": {"baseUrl": f"http://127.0.0.1:{fake_port}/v1", "apiKey": "test-key"},
                   "instances": {"localEndpoint": {"driver": "localEndpoint"}}}, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_ENDPOINT", "OMB_", "XAI_", "BOX_", "OPENCODE_", "ANTHROPIC_", "CLAUDE"))}
    env.update(OMB_DATA_DIR=data_dir, OMB_PORT=str(port), OMB_WEBHOOK_PORT=str(free_port()))
    engine = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(160):
        try:
            if request(port, "GET", "/api/health")[0] == 200:
                break
        except OSError:
            time.sleep(0.25)
    _, instances = request(port, "GET", "/api/instances")
    local = next(i for i in instances["instances"] if i["instanceId"] == "localEndpoint")
    model = next(o["id"] for o in local["models"]["options"] if o["id"].endswith("fake/echo-1"))
    bot = request(port, "GET", "/api/bots")[1]["bots"][0]
    status, body = request(port, "PATCH", f"/api/bots/{bot['id']}",
                           {"name": name, "modelSelection": {"instanceId": "localEndpoint", "model": model}})
    assert status == 200, (status, body)
    return engine, port, data_dir, bot["id"]


def room(port, room_id):
    _, fleet = request(port, "GET", "/api/bots")
    return next(g for g in fleet["groups"] if g["id"] == room_id)


def settle(port, room_id, bot_texts):
    deadline = time.time() + 60
    while time.time() < deadline:
        current = room(port, room_id)
        texts = [m for m in current.get("messages", []) if m.get("role") == "bot" and m.get("kind") == "text"]
        if len(texts) >= bot_texts and not current.get("busyBotId"):
            return current
        time.sleep(0.2)
    raise SystemExit(f"room did not settle: {room(port, room_id)}")


def main():
    work = tempfile.mkdtemp(prefix="mixed-e2e-")
    record = os.path.join(work, "record.ndjson")
    fake_port = free_port()
    fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_openai.py"), str(fake_port), record],
                            env={**os.environ, "FAKE_OPENAI_RECORD_SYSTEM": "1"})
    host, host_port, host_dir, alfa = start(fake_port, "Alfa")
    guest, guest_port, guest_dir, beta = start(fake_port, "Beta")
    try:
        # the engines a room may call: checked, and never written to disk
        assert request(host_port, "PUT", "/api/peer-engines", {"engines": [{"id": "srv", "url": "ftp://x"}]})[0] == 400
        status, body = request(host_port, "PUT", "/api/peer-engines", {"name": "Mac di prova", "engines": [
            {"id": "srv", "name": "Server", "url": f"http://127.0.0.1:{guest_port}", "token": "local-test-token"}]})
        assert status == 200 and body["engines"] == [{"id": "srv", "name": "Server"}], (status, body)
        assert "local-test-token" not in open(os.path.join(host_dir, "config.json")).read()

        # a guest from an engine the host does not know is dropped
        status, body = request(host_port, "POST", "/api/groups", {"name": "Misto", "memberIds": [alfa], "guests": [
            {"peerId": "srv", "botId": beta, "name": "Beta", "color": "green"}, {"peerId": "nope", "botId": "x", "name": "X"}]})
        assert status == 201, (status, body)
        group = body["group"]
        assert [g["name"] for g in group["guests"]] == ["Beta"], group
        room_id = group["id"]
        guest_id = f"peer:srv:{beta}"
        # a guest can be the default responder
        status, body = request(host_port, "PATCH", f"/api/groups/{room_id}", {"defaultResponder": {"kind": "member", "botId": guest_id}})
        assert status == 200 and body["group"]["defaultResponder"] == {"kind": "member", "botId": guest_id}, (status, body)
        assert request(host_port, "PATCH", f"/api/groups/{room_id}", {"defaultResponder": {"kind": "everyone"}})[0] == 200

        assert request(host_port, "POST", f"/api/groups/{room_id}/messages", {"text": "Ciao a tutti"})[0] == 202
        current = settle(host_port, room_id, 2)
        replies = [m for m in current["messages"] if m.get("role") == "bot" and m.get("kind") == "text"]
        assert [m["from"]["name"] for m in replies] == ["Alfa", "Beta"], replies
        assert replies[1]["from"] == {"botId": guest_id, "name": "Beta", "color": "green"}, replies[1]
        assert replies[1].get("guestRef"), replies[1]
        with open(record) as f:
            sent = [json.loads(line) for line in f]
        beta_turn = sent[-1]
        assert "(Reply to the conversation above as Beta.)" in beta_turn["last"], beta_turn
        assert "Alfa: Ciao! Sono il modello finto." in beta_turn["last"], beta_turn
        assert "@Alfa, @Beta" in beta_turn["system"] and "the room \"Misto\"" in beta_turn["system"], beta_turn["system"]

        # on the guest: a mirror room, Beta's reply in it, nothing unread
        _, fleet = request(guest_port, "GET", "/api/bots")
        mirror = next(g for g in fleet["groups"] if g.get("guest"))
        assert mirror["guest"]["conversationId"] == room_id and mirror["guest"]["hostName"] == "Mac di prova", mirror
        assert mirror["memberIds"] == [beta] and mirror["unread"] is False, mirror
        texts = [(m["role"], m.get("from", {}).get("name"), m["text"]) for m in mirror["messages"] if m["kind"] == "text"]
        assert texts == [("user", None, "Ciao a tutti"), ("bot", "Alfa", "Ciao! Sono il modello finto."),
                         ("bot", "Beta", "Ciao! Sono il modello finto.")], texts
        assert request(guest_port, "POST", f"/api/groups/{mirror['id']}/messages", {"text": "no"})[0] == 409

        # a second round: Beta only, the mirror gains just the new message
        assert request(host_port, "POST", f"/api/groups/{room_id}/messages", {"text": "@Beta e adesso?"})[0] == 202
        settle(host_port, room_id, 3)
        mirror = room(guest_port, mirror["id"])
        texts = [m["text"] for m in mirror["messages"] if m["kind"] == "text"]
        assert texts == ["Ciao a tutti", "Ciao! Sono il modello finto.", "Ciao! Sono il modello finto.", "@Beta e adesso?",
                         "Ciao! Sono il modello finto."], texts

        # a guest engine gone: a chip on the host, the room free again
        request(host_port, "PUT", "/api/peer-engines", {"engines": []})
        assert request(host_port, "POST", f"/api/groups/{room_id}/messages", {"text": "@Beta ci sei?"})[0] == 202
        deadline = time.time() + 20
        while time.time() < deadline:
            current = room(host_port, room_id)
            chips = [m for m in current["messages"] if m.get("kind") == "activity" and "not connected" in m["tool"]["name"]]
            if chips and not current.get("busyBotId"):
                break
            time.sleep(0.2)
        assert chips, current["messages"][-1]
        print("mixed rooms e2e: ok")
    finally:
        for process in (host, guest, fake):
            process.terminate()
        for folder in (host_dir, guest_dir, work):
            shutil.rmtree(folder, ignore_errors=True)


main()
