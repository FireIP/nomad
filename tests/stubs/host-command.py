#!/usr/bin/env python3
"""Local-only substitutes for the commands used by the two-host simulation."""

import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


root = Path(os.environ["SIM_ROOT"])
host = os.environ["SIM_HOST"]
peer = "b" if host == "a" else "a"
state = root / host / "domstate"
command = Path(sys.argv[0]).name
args = sys.argv[1:]


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


if command == "ssh":
    while args and args[0] == "-o":
        args = args[2:]
    route, remote_command = args
    with (root / "ssh.log").open("a") as log:
        log.write(f"{host} {route} {remote_command}\n")
    if route in (root / "down").read_text().splitlines():
        sys.exit(255)
    env = os.environ.copy()
    env.update(SIM_HOST=peer, HOME=str(root / peer / "home"))
    os.execve("/bin/bash", ["bash", "-c", remote_command], env)
elif command == "virsh":
    if args[:2] == ["--connect", "qemu:///system"]:
        args = args[2:]
    if os.environ.get("LIBVIRT_DEFAULT_URI") != "qemu:///system":
        fail("virsh stub requires qemu:///system")
    action = args[0]
    with (root / "virsh.log").open("a") as log:
        log.write(f"{host} {' '.join(args)}\n")
    if action == "dominfo":
        sys.exit(0 if state.exists() else 1)
    elif action == "domstate":
        if not state.exists():
            fail("no domain")
        print(state.read_text().strip())
    elif action == "start":
        if not state.exists():
            fail("no domain")
        state.write_text("running")
        print("Domain started")
    elif action == "define":
        ET.parse(args[1])
        state.write_text("shut off")
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
        (root / peer / "domstate").write_text("running")
        state.unlink()
elif command == "uname":
    print(f"host-{host}")
elif command == "xmllint":
    # Only the two takeover queries; migration itself is deliberately not run.
    xml = ET.fromstring(sys.stdin.read())
    query = args[1]
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
