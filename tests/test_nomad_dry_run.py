"""Regression tests for dry-run location-record handling."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
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
import time
import xml.etree.ElementTree as ET

root = Path(os.environ["SIM_ROOT"])
host = os.environ["SIM_HOST"]
peer = "b" if host == "a" else "a"
domain = os.environ.get("DOMAIN", "nomad")
args = sys.argv[1:]
command = Path(sys.argv[0]).name
if command == "uname" and args == ["-n"]:
    print(f"host-{host}")
    raise SystemExit(0)
if command == "ssh":
    while args and args[0] == "-o":
        args = args[2:]
    route, remote = args
    if remote == "true":
        if os.environ.get("SIM_SSH_UNREACHABLE") == "1":
            raise SystemExit(1)
        raise SystemExit(0)
    env = os.environ.copy()
    env.update(SIM_HOST=peer, HOME=str(root / peer / "home"))
    raise SystemExit(subprocess.run(["bash", "-c", remote], env=env).returncode)
if command == "virsh":
    if args[:2] == ["--connect", "qemu:///system"]:
        args = args[2:]
    if args[:3] == ["list", "--all", "--name"]:
        if host == "b" and os.environ.get("SIM_FAIL_PEER_STATE") == "1":
            raise SystemExit(1)
        state = root / host / ("domstate" if domain == "nomad" else f"{domain}.domstate")
        if state.exists():
            print(domain)
        raise SystemExit(0)
    if args[0] == "domstate":
        gate = root / "pause-domstate"
        started = root / "domstate.started"
        if host == "a" and gate.exists() and not started.exists():
            started.touch()
            while not (root / "domstate.release").exists():
                time.sleep(0.02)
        state = root / host / ("domstate" if domain == "nomad" else f"{domain}.domstate")
        if not state.exists():
            raise SystemExit(1)
        print(state.read_text().strip())
        raise SystemExit(0)
    if args[0] == "define":
        (root / host / "defined").write_text("defined")
        raise SystemExit(0)
if command == "xmllint":
    if args[:2] == ["--xpath", "string(/domain/name)"]:
        print(ET.parse(args[2]).findtext("name") or "")
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

    def run_start_with_peer_state_failure(self):
        env = self.environment()
        env["SIM_FAIL_PEER_STATE"] = "1"
        return subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "start", "--yes", "--no-viewer"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )

    def record_path(self, host):
        return self.root / host / "home/.local/state/nomad/location"

    def domain_record_path(self, host, domain):
        return self.root / host / f"home/.local/state/nomad/{domain}/location"

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

    def test_takeover_with_same_owner_and_stale_peer_generation_is_conflict(self):
        (self.root / "b/domstate").write_text("shut off")
        for host, generation, event in (("a", 2, "takeover"), ("b", 1, "migrated")):
            path = self.record_path(host)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "# nomad location record\n"
                f"OWNER=strong\nOWNER_HOST=host-a\nGEN={generation}\n"
                f"SINCE=2026-10-27T00:00:00+00:00\nEVENT={event}\n"
            )

        result = self.run_dry_run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("after a takeover: the copies have diverged", result.stdout)

    def test_where_does_not_reconcile_during_migration(self):
        stale = (
            "# nomad location record\n"
            "OWNER=weak\nOWNER_HOST=host-b\nGEN=1\n"
            "SINCE=2026-10-27T00:00:00+00:00\nEVENT=start\n"
        )
        for host in ("a", "b"):
            path = self.record_path(host)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(stale)
        (self.root / "pause-domstate").touch()
        started = self.root / "migration.started"
        release = self.root / "migration.release"
        (self.root / "scripts/migrate.sh").write_text(
            "#!/usr/bin/env bash\n"
            "touch \"$SIM_ROOT/migration.started\"\n"
            "while [ ! -e \"$SIM_ROOT/migration.release\" ]; do sleep 0.02; done\n"
        )
        (self.root / "scripts/migrate.sh").chmod(0o755)
        migration = subprocess.Popen(
            [str(self.root / "a/home/.local/bin/nomad"), "migrate", "--route", "peer"],
            env=self.environment(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "domstate.started").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(
                (self.root / "domstate.started").exists(),
                "migration did not acquire its lock before querying libvirt",
            )
            before_precheck = {
                host: self.record_path(host).read_text() for host in ("a", "b")
            }
            where = subprocess.run(
                [str(self.root / "a/home/.local/bin/nomad"), "where"],
                env=self.environment(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=5,
            )
            self.assertEqual(where.returncode, 0, where.stdout)
            self.assertIn("checking location records without changing them", where.stdout)
            self.assertEqual(
                {host: self.record_path(host).read_text() for host in ("a", "b")},
                before_precheck,
            )

            (self.root / "domstate.release").touch()
            deadline = time.monotonic() + 5
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "migration did not reach its running phase")
            before = {host: self.record_path(host).read_text() for host in ("a", "b")}

            where = subprocess.run(
                [str(self.root / "a/home/.local/bin/nomad"), "where"],
                env=self.environment(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=5,
            )
            self.assertEqual(where.returncode, 0, where.stdout)
            self.assertIn("checking location records without changing them", where.stdout)
            self.assertIn("EVENT=migrating", before["a"])
            self.assertEqual(
                {host: self.record_path(host).read_text() for host in ("a", "b")},
                before,
            )
        finally:
            (self.root / "domstate.release").touch()
            release.touch()
            output, _ = migration.communicate(timeout=10)
        self.assertEqual(migration.returncode, 0, output)

    def test_detached_viewer_does_not_hold_migration_lock(self):
        self.addCleanup(lambda: (self.root / "viewer.release").touch())
        config = self.root / "a/home/.config/nomad/config"
        config.write_text(
            'ROLE=strong\nROUTES="peer"\nAUTO_INFLATE=0\n'
            'VIEWER=1\nVIEWER_SOURCE=1\nVIEWER_CMD=virt-viewer\n'
        )
        viewer = self.bin / "virt-viewer"
        viewer.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "from pathlib import Path\n"
            "import time\n"
            "if os.environ.get('SIM_HOST') == 'a':\n"
            "    root = Path(os.environ['SIM_ROOT'])\n"
            "    (root / 'viewer.started').touch()\n"
            "    while not (root / 'viewer.release').exists():\n"
            "        time.sleep(0.02)\n"
        )
        viewer.chmod(0o755)
        env = self.environment()
        env["DISPLAY"] = ":0"

        result = subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "migrate", "--route", "peer"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        deadline = time.monotonic() + 5
        while not (self.root / "viewer.started").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / "viewer.started").exists(), "local viewer was not launched")

        where = subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "where"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=5,
        )
        (self.root / "viewer.release").touch()
        self.assertEqual(where.returncode, 0, where.stdout)
        self.assertNotIn("checking location records without changing them", where.stdout)

    def test_start_refuses_when_peer_state_query_fails(self):
        (self.root / "a/domstate").write_text("shut off")
        (self.root / "b/domstate").write_text("running")
        stale = (
            "# nomad location record\n"
            "OWNER=weak\nOWNER_HOST=host-b\nGEN=2\n"
            "SINCE=2026-10-27T00:00:00+00:00\nEVENT=migrated\n"
        )
        for host in ("a", "b"):
            path = self.record_path(host)
            path.parent.mkdir(parents=True)
            path.write_text(stale)

        result = self.run_start_with_peer_state_failure()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not verify 'nomad' state on both hosts", result.stdout)
        self.assertEqual(self.record_path("a").read_text(), stale)
        self.assertEqual(self.record_path("b").read_text(), stale)
        self.assertEqual((self.root / "a/domstate").read_text(), "shut off")

    def test_nondefault_domain_state_is_isolated_and_synced_to_peer(self):
        (self.root / "a/nomad-test.domstate").write_text("running")
        default = (
            "# nomad location record\n"
            "OWNER=weak\nOWNER_HOST=host-b\nGEN=7\n"
            "SINCE=2026-10-27T00:00:00+00:00\nEVENT=migrated\n"
        )
        for host in ("a", "b"):
            path = self.record_path(host)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(default)
        env = self.environment()
        env["DOMAIN"] = "nomad-test"

        result = subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "where"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.record_path("a").read_text(), default)
        self.assertEqual(self.record_path("b").read_text(), default)
        for host in ("a", "b"):
            self.assertIn("OWNER=strong", self.domain_record_path(host, "nomad-test").read_text())

    def test_takeover_rejects_saved_xml_for_another_domain(self):
        state_dir = self.root / "a/home/.local/state/nomad/nomad-test"
        state_dir.mkdir(parents=True)
        (state_dir / "domain.xml").write_text("<domain><name>nomad</name></domain>")
        env = self.environment()
        env.update(DOMAIN="nomad-test", SIM_SSH_UNREACHABLE="1")

        result = subprocess.run(
            [str(self.root / "a/home/.local/bin/nomad"), "takeover"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("belongs to 'nomad', not 'nomad-test'", result.stdout)
        self.assertFalse((self.root / "a/defined").exists())


if __name__ == "__main__":
    unittest.main()
