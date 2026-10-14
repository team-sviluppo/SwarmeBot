#!/usr/bin/env python3
"""A docker stand-in for the Local VM parity scenario.

Speaks just enough of the CLI that both engines report the same ready
desktop, then speaks a one-tool MCP server when argv contains `mcp`
(the stdio bridge into Cua Driver).
"""
import base64
import json
import os
import sys

args = sys.argv[1:]
data = os.environ.get("OMB_DATA_DIR", "")
workspace = data + "/vm-home"
labels = {
    "com.swarmebot.local-vm": "1",
    "com.swarmebot.cua-driver": "0.20.0",
    "com.swarmebot.cua-base": "sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b",
    "com.swarmebot.image-layer": "3",
    "com.swarmebot.workspace": "1",
}
image = "localhost/swarmebot/cua-local-vm:driver-0.20.0-v3"
png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 520 + b"IEND"


def reply(text):
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    sys.exit(0)


if args[:3] == ["info", "--format", "{{.ServerVersion}}"]:
    reply("27.0.3")
if args[:3] == ["image", "inspect", image]:
    reply(json.dumps([{"Id": "sha256:abc123", "Config": {"Labels": labels}}]))
if args[:2] == ["inspect", "swarmebot-computer"]:
    reply(json.dumps([{
        "Config": {"Image": image, "Labels": labels, "Env": []},
        "Image": "sha256:abc123",
        "State": {"Running": True},
        "HostConfig": {
            "PortBindings": {"6901/tcp": [{"HostIp": "127.0.0.1"}]},
            "Memory": 4294967296, "MemorySwap": 4294967296, "NanoCpus": 2000000000,
            "PidsLimit": 512, "CapDrop": ["ALL"], "CapAdd": ["SETGID", "SETUID"],
            "Privileged": False, "IpcMode": "private", "ShmSize": 536870912,
            "CgroupnsMode": "private", "Devices": [], "SecurityOpt": [],
            "RestartPolicy": {"Name": "no"},
        },
        "Mounts": [{"Type": "bind", "Source": workspace, "Destination": "/home/cua/workspace", "RW": True}],
    }]))
if args[-1:] == ["--version"] or "--version" in args:
    reply("cua-driver 0.20.0")
if "health_report" in args:
    reply(json.dumps({"schema_version": "1", "overall": "ok", "checks": []}))
if "base64" in args:
    reply(base64.b64encode(png).decode())
if "mcp" in args:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "cua", "version": "0"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "ping", "description": "parity", "inputSchema": {"type": "object", "properties": {}}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "pong dal computer"}]}
        elif str(method).startswith("notifications/"):
            continue
        else:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message.get("id"), "error": {"code": -32601, "message": "no"}}) + "\n")
            sys.stdout.flush()
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
        sys.stdout.flush()
    sys.exit(0)
# status, get_desktop_state, and anything else the readiness probe runs
sys.exit(0)
