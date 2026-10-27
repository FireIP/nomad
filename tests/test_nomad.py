"""Regression tests for the wrapper, not real libvirt or migration integration tests."""

import errno
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import time
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
STUB = Path(__file__).resolve().parent / "stubs" / "host-command.py"


class NomadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nomad-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("nomad", "lib.sh", "inflate.sh"):
            shutil.copy2(REPO / "scripts" / name, scripts / name)
        stub = self.root / "host-command.py"
        shutil.copy2(STUB, stub)
        stub.chmod(0o755)
        for name in ("ssh", "virsh", "uname", "xmllint", "notify-send"):
            (self.bin / name).symlink_to(stub)
        (scripts / "migrate.sh").symlink_to(stub)
        for host, role in (("a", "strong"), ("b", "weak")):
            home = self.root / host / "home"
            config = home / ".config/nomad/config"
            config.parent.mkdir(parents=True)
            config.write_text(
                f'ROLE={role}\nROUTES="ethernet wifi"\nAUTO_INFLATE=0\nVIEWER=0\n'
            )
            installed = home / ".local/bin/nomad"
            installed.parent.mkdir(parents=True)
            installed.symlink_to(scripts / "nomad")
            disk = self.root / host / "disk.qcow2"
            nvram = self.root / host / "vars.fd"
            disk.touch()
            nvram.touch()
            (self.root / host / "domain.xml").write_text(
                f"<domain><name>nomad</name><os><nvram>{nvram}</nvram></os><devices>"
                f"<disk device='disk'><source file='{disk}'/></disk>"
                "</devices></domain>"
            )
        (self.root / "down").write_text("")

    def environment(self, host, **overrides):
        env = os.environ.copy()
        for key in ("NOMAD_CONFIG", "NOMAD_STATE_DIR", "XDG_STATE_HOME", "DOMAIN",
                    "BASH_ENV", "ENV", "FORCE"):
            env.pop(key, None)
        env.update(
            HOME=str(self.root / host / "home"),
            PATH=f"{self.bin}:{env['PATH']}",
            SIM_ROOT=str(self.root),
            SIM_HOST=host,
        )
        env.update(overrides)
        return env

    def executable(self, host):
        return self.root / host / "home/.local/bin/nomad"

    def run_nomad(self, host, *args, rc=0, **env):
        result = subprocess.run(
            [str(self.executable(host)), *args],
            env=self.environment(host, **env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, rc, result.stdout)
        return result.stdout

    def run_terminal(self, host, args, prompt, answer, rc=0):
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(
                self.executable(host),
                [str(self.executable(host)), *args],
                self.environment(host),
            )
        output = b""
        answered = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], 0.1)
                if not ready:
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output += chunk
                if not answered and prompt.encode() in output:
                    os.write(fd, (answer + "\n").encode())
                    answered = True
            else:
                self.fail(f"terminal command timed out: {output!r}")
        finally:
            os.close(fd)
            while True:
                exited, status = os.waitpid(pid, os.WNOHANG)
                if exited:
                    break
                if time.monotonic() >= deadline:
                    # Kill only this child's process group, including its stubs.
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    _, status = os.waitpid(pid, 0)
                    break
                time.sleep(0.01)
        text = output.decode().replace("\r", "")
        self.assertTrue(answered, text)
        self.assertEqual(os.waitstatus_to_exitcode(status), rc, text)
        return text

    def state(self, host, value):
        path = self.root / host / "domstate"
        if value is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(value)

    def assert_state(self, host, value):
        path = self.root / host / "domstate"
        self.assertEqual(path.read_text() if path.exists() else None, value)

    def offline(self):
        (self.root / "down").write_text("ethernet\nwifi\n")

    def record_path(self, host):
        return self.root / host / "home/.local/state/nomad/location"

    def record(self, host):
        return dict(
            line.split("=", 1) for line in self.record_path(host).read_text().splitlines()
            if not line.startswith("#")
        )

    def seed_record(self, host, owner, gen=1, event="start"):
        self.run_nomad(
            host, "_record", "set", owner, str(gen), event,
            "2026-10-27T00:00:00+00:00", "-",
        )

    def assert_records(self, owner, gen, event=None):
        a, b = self.record("a"), self.record("b")
        self.assertEqual(a, b)
        self.assertEqual(a["OWNER"], owner)
        self.assertEqual(a["GEN"], str(gen))
        if event:
            self.assertEqual(a["EVENT"], event)

    def test_where_infers_and_syncs_then_start_uses_installed_symlink(self):
        self.state("a", "shut off")
        self.run_nomad("a", "where")
        self.assert_records("strong", 1, "inferred")
        self.run_nomad("a", "start")
        self.assert_state("a", "running")
        self.assertTrue((self.record_path("a").parent / "domain.xml").exists())

    def test_reachable_running_peer_blocks_start(self):
        self.state("a", "shut off")
        self.state("b", "running")
        self.assertIn("refusing to start a second copy", self.run_nomad("a", "start", rc=1))
        self.assert_state("a", "shut off")

    def test_offline_owner_requires_confirmation_or_yes_on_either_host(self):
        self.offline()
        for host, role in (("a", "strong"), ("b", "weak")):
            with self.subTest(host=host):
                self.state(host, "shut off")
                self.seed_record(host, role)
                self.assertIn("not started", self.run_nomad(host, "start", rc=1))
                self.assert_state(host, "shut off")
                self.run_terminal(host, ["start"], "[y/N]", "n", rc=1)
                self.assert_state(host, "shut off")
                self.run_terminal(host, ["start"], "[y/N]", "y")
                self.assert_state(host, "running")
                self.state(host, "shut off")
                self.run_nomad(host, "start", "--yes")
                self.assert_state(host, "running")

    def test_offline_owner_elsewhere_refuses_even_with_yes(self):
        self.offline()
        self.state("a", "shut off")
        self.seed_record("a", "weak")
        self.assertIn("nomad takeover", self.run_nomad("a", "start", "--yes", rc=1))
        self.assert_state("a", "shut off")

    def test_missing_record_infers_offline_owner_and_records_start(self):
        self.offline()
        self.state("a", "shut off")
        self.assertIn("guessed from libvirt", self.run_nomad("a", "status"))
        self.run_nomad("a", "start", "--yes")
        self.assert_state("a", "running")
        self.assertEqual(self.record("a")["OWNER"], "strong")

    def test_migration_both_directions_updates_owner_and_saves_source_xml(self):
        self.state("a", "running")
        for source, target, owner, gen in (
            ("a", "b", "weak", 2), ("b", "a", "strong", 3)
        ):
            with self.subTest(source=source):
                self.run_nomad(source, "migrate")
                self.assert_state(source, None)
                self.assert_state(target, "running")
                self.assert_records(owner, gen, "migrated")
                self.assertTrue((self.record_path(source).parent / "domain.xml").exists())

    def test_migration_of_nondefault_domain_tells_peer_which_domain(self):
        self.state("a", None)
        (self.root / "b/nomad-test.domstate").write_text("running")
        self.run_nomad("b", "migrate", "--inflate", "--viewer", DOMAIN="nomad-test")
        self.assertEqual((self.root / "a/nomad-test.domstate").read_text(), "running")
        peer_calls = [
            line for line in (self.root / "ssh.log").read_text().splitlines()
            if line.startswith("b ") and ".local/bin/nomad" in line
        ]
        for action in ("_record get", "_record set", "inflate", "viewer"):
            calls = [line for line in peer_calls if f"nomad {action}" in line]
            self.assertTrue(calls, f"no peer '{action}' call")
            self.assertTrue(all("DOMAIN=nomad-test " in line for line in calls), calls)
        self.assertIn("OWNER=strong", (self.root / "a/home/.local/state/nomad/nomad-test/location").read_text())

    def test_failed_migration_restores_record_and_dry_run_does_not_move_vm(self):
        self.state("a", "running")
        self.run_nomad("a", "where")
        before = self.record("a")
        self.run_nomad("a", "migrate", "--dry-run")
        self.assertEqual(self.record("a"), before)
        self.assert_state("a", "running")
        self.run_nomad("a", "migrate", rc=1, SIM_MIGRATE_FAIL="1")
        self.assertEqual(self.record("a"), before)
        self.assert_state("a", "running")
        self.assert_state("b", None)

    def test_takeover_confirmation_and_conflict_until_stale_copy_undefined(self):
        self.state("a", "running")
        self.run_nomad("a", "migrate")
        self.offline()
        self.run_nomad("a", "takeover", rc=1)
        self.assert_state("a", None)
        self.run_terminal("a", ["takeover"], "Type the domain name", "wrong", rc=1)
        self.assert_state("a", None)
        self.run_terminal("a", ["takeover"], "Type the domain name", "nomad")
        self.assert_state("a", "running")
        self.assertEqual(self.record("a")["EVENT"], "takeover")
        self.state("b", "shut off")
        (self.root / "down").write_text("")
        for host, command in (("a", "where"), ("b", "start"), ("a", "migrate")):
            self.assertIn("diverged", self.run_nomad(host, command, rc=1))
        self.state("b", None)
        self.run_nomad("b", "where")
        self.assert_records("strong", 3, "takeover")

    def test_takeover_refuses_reachable_peer_or_missing_definition(self):
        self.assertIn("reachable", self.run_nomad("a", "takeover", rc=1))
        self.offline()
        self.assertIn("no saved definition", self.run_nomad("a", "takeover", rc=1))
        self.assert_state("a", None)

    def test_interrupted_migration_is_inferred_and_repaired_when_peer_returns(self):
        self.seed_record("a", "strong", event="migrating")
        self.state("b", "running")
        self.offline()
        self.run_nomad("a", "start", "--yes", rc=1)
        self.assert_state("a", None)
        (self.root / "down").write_text("")
        self.run_nomad("a", "where")
        self.assert_records("weak", 2, "inferred")

    def test_stale_definition_cannot_start_when_records_agree_peer_owns_vm(self):
        for host in ("a", "b"):
            self.state(host, "shut off")
            self.seed_record(host, "weak")
        self.assertIn("stale", self.run_nomad("a", "start", rc=1))
        self.assert_state("a", "shut off")

    def test_live_state_repairs_wrong_owner(self):
        for host in ("a", "b"):
            self.seed_record(host, "strong")
        self.state("b", "shut off")
        self.run_nomad("a", "where")
        self.assert_records("weak", 2, "repaired")

    def test_viewer_and_status_explain_offline_location(self):
        self.offline()
        self.state("a", "shut off")
        for owner, message in (("strong", "nomad start"), ("weak", "other host")):
            with self.subTest(owner=owner):
                self.seed_record("a", owner)
                self.assertIn(message, self.run_nomad("a", "viewer", rc=1))
                self.assertIn("Location record:", self.run_nomad("a", "status"))
                self.assertIn(owner, self.run_nomad("a", "where"))

    def test_wifi_fallback_when_ethernet_is_down(self):
        self.state("a", "shut off")
        (self.root / "down").write_text("ethernet\n")
        self.assertIn("via wifi", self.run_nomad("a", "where"))
        self.assert_records("strong", 1)


if __name__ == "__main__":
    unittest.main()
