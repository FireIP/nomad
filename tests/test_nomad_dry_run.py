"""Regression tests for dry-run location-record handling."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class DryRunReconcileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nomad-dry-run-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("nomad", "lib.sh"):
            shutil.copy2(REPO / "scripts" / name, scripts / name)
        (scripts / "migrate.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        (scripts / "migrate.sh").chmod(0o755)
        stub = self.root / "host-command.py"
        stub.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["SIM_ROOT"])
host = os.environ["SIM_HOST"]
peer = "b" if host == "a" else "a"
args = sys.argv[1:]
command = Path(sys.argv[0]).name
if command == "ssh":
    while args and args[0] == "-o":
        args = args[2:]
    route, remote = args
    if remote == "true":
        raise SystemExit(0)
    env = os.environ.copy()
    env.update(SIM_HOST=peer, HOME=str(root / peer / "home"))
    raise SystemExit(subprocess.run(["bash", "-c", remote], env=env).returncode)
if command == "virsh":
    if args[:2] == ["--connect", "qemu:///system"]:
        args = args[2:]
    if args[0] == "domstate":
        state = root / host / "domstate"
        if not state.exists():
            raise SystemExit(1)
        print(state.read_text().strip())
        raise SystemExit(0)
raise SystemExit(1)
"""
        )
        stub.chmod(0o755)
        for name in ("ssh", "virsh", "uname", "xmllint"):
            (self.bin / name).symlink_to(stub)
        for host, role in (("a", "strong"), ("b", "weak")):
            home = self.root / host / "home"
            config = home / ".config/nomad/config"
            config.parent.mkdir(parents=True)
            config.write_text(f'ROLE={role}\nROUTES="peer"\nAUTO_INFLATE=0\nVIEWER=0\n')
            installed = home / ".local/bin/nomad"
            installed.parent.mkdir(parents=True)
            installed.symlink_to(scripts / "nomad")
        (self.root / "a/domstate").write_text("running")

    def environment(self):
        env = os.environ.copy()
        for key in ("NOMAD_CONFIG", "NOMAD_STATE_DIR", "XDG_STATE_HOME", "DOMAIN"):
            env.pop(key, None)
        env.update(
            HOME=str(self.root / "a/home"),
            PATH=f"{self.bin}:{env['PATH']}",
            SIM_ROOT=str(self.root),
            SIM_HOST="a",
        )
        return env

    def run_dry_run(self):
        return subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "migrate", "--dry-run"],
            env=self.environment(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )

    def record_path(self, host):
        return self.root / host / "home/.local/state/nomad/location"

    def test_missing_records_remain_missing(self):
        result = self.run_dry_run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record_path("a").exists())
        self.assertFalse(self.record_path("b").exists())

    def test_stale_records_remain_unchanged(self):
        stale = (
            "# nomad location record\n"
            "OWNER=weak\nOWNER_HOST=host-b\nGEN=1\n"
            "SINCE=2026-10-27T00:00:00+00:00\nEVENT=start\n"
        )
        for host in ("a", "b"):
            path = self.record_path(host)
            path.parent.mkdir(parents=True)
            path.write_text(stale)

        result = self.run_dry_run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.record_path("a").read_text(), stale)
        self.assertEqual(self.record_path("b").read_text(), stale)

    def test_conflicts_are_still_detected(self):
        (self.root / "b/domstate").write_text("running")

        result = self.run_dry_run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("two copies are running", result.stdout)
        self.assertFalse(self.record_path("a").exists())
        self.assertFalse(self.record_path("b").exists())


if __name__ == "__main__":
    unittest.main()
