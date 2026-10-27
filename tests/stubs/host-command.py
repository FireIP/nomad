#!/usr/bin/env python3
"""Local-only substitutes for the commands used by the two-host simulation.

A domain's libvirt state lives in $SIM_ROOT/<host>/domstate for 'nomad' and in
<host>/<domain>.domstate for any other domain; no file means not defined.
"""

import os
from pathlib import Path
import sys
import time
import xml.etree.ElementTree as ET


root = Path(os.environ["SIM_ROOT"])
host = os.environ["SIM_HOST"]
peer = "b" if host == "a" else "a"
command = Path(sys.argv[0]).name
args = sys.argv[1:]


def state_file(on_host, domain):
    return root / on_host / ("domstate" if domain == "nomad" else f"{domain}.domstate")


state = state_file(host, os.environ.get("DOMAIN", "nomad"))


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def routes_down():
    down = root / "down"
    return down.read_text().splitlines() if down.exists() else []


if command == "ssh":
    while args and args[0] == "-o":
        args = args[2:]
    route, remote_command = args
    with (root / "ssh.log").open("a") as log:
        log.write(f"{host} {route} {remote_command}\n")
    if os.environ.get("SIM_SSH_UNREACHABLE") == "1" or route in routes_down():
        sys.exit(255)
    env = os.environ.copy()
    # A real ssh session does not inherit the caller's environment.
    for key in ("DOMAIN", "LIBVIRT_DEFAULT_URI", "LC_ALL"):
        env.pop(key, None)
    env.update(SIM_HOST=peer, HOME=str(root / peer / "home"))
    os.execve("/bin/bash", ["bash", "-c", remote_command], env)
elif command == "virsh":
    if args[:2] == ["--connect", "qemu:///system"]:
        args = args[2:]
    elif os.environ.get("LIBVIRT_DEFAULT_URI") != "qemu:///system":
        fail("virsh stub requires qemu:///system")
    action = args[0]
    with (root / "virsh.log").open("a") as log:
        log.write(f"{host} {' '.join(args)}\n")
    if args[:3] == ["list", "--all", "--name"]:
        if host == "b" and os.environ.get("SIM_FAIL_PEER_STATE") == "1":
            fail("cannot connect")
        if (root / host / "domstate").exists():
            print("nomad")
        for other in sorted((root / host).glob("*.domstate")):
            print(other.name[: -len(".domstate")])
    elif action == "dominfo":
        sys.exit(0 if state_file(host, args[1]).exists() else 1)
    elif action == "domstate":
        # Optional gate so a test can hold the first domstate query on host a.
        if host == "a" and (root / "pause-domstate").exists() and not (root / "domstate.started").exists():
            (root / "domstate.started").touch()
            while not (root / "domstate.release").exists():
                time.sleep(0.02)
        path = state_file(host, args[1])
        if not path.exists():
            fail("no domain")
        print(path.read_text().strip())
    elif action == "start":
        path = state_file(host, args[1])
        if not path.exists():
            fail("no domain")
        path.write_text("running")
        print("Domain started")
    elif action == "define":
        name = ET.parse(args[1]).findtext("name") or "nomad"
        state_file(host, name).write_text("shut off")
        print("Domain defined")
    elif action == "dumpxml":
        if not state.exists():
            fail("no domain")
        print((root / host / "domain.xml").read_text())
    else:
        fail(f"unsupported virsh command: {args}")
elif command == "migrate.sh":
    if "--dry-run" in args:
        print("stub dry run")
    elif os.environ.get("SIM_MIGRATE_FAIL") == "1":
        fail("stub migration failed")
    else:
        if not state.exists() or state.read_text() != "running":
            fail("source must be running")
        state_file(peer, os.environ.get("DOMAIN", "nomad")).write_text("running")
        state.unlink()
elif command == "uname":
    print(f"host-{host}")
elif command == "xmllint":
    query = args[1]
    if query == "string(/domain/name)":
        print(ET.parse(args[2]).findtext("name") or "")
        sys.exit(0)
    # The takeover queries read the definition from stdin.
    xml = ET.fromstring(sys.stdin.read())
    if query == "//devices/disk[@device='disk']/source/@file":
        for disk in xml.findall("./devices/disk[@device='disk']/source"):
            print(f' file="{disk.attrib["file"]}"', end="")
    elif query == "string(//os/nvram)":
        print(xml.findtext("./os/nvram", default=""))
    else:
        fail(f"unsupported XPath: {query}")
elif command == "notify-send":
    pass
else:
    fail(f"unexpected stub: {command}")
