import concurrent.futures
import json
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from config_db import Store


class RemoteScriptTest(unittest.TestCase):
    def test_child_stdin_cannot_consume_remaining_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            ssh = Path(tmp) / "ssh"
            ssh.write_text('#!/usr/bin/env bash\nexec bash -c "${!#}"\n')
            ssh.chmod(0o755)
            script = """source scripts/lib/common.sh
remote_exec_private_stdin node.lab.test PANEL_ADMIN_PASSWORD 'argument with spaces' <<'REMOTE'
set -eu
cat >/dev/null
[[ "$1" == 'argument with spaces' && "$PANEL_ADMIN_PASSWORD" == secret ]]
echo completed
REMOTE
"""
            env = {**os.environ, "PATH":tmp + os.pathsep + os.environ["PATH"], "PANEL_ADMIN_PASSWORD":"secret"}
            result = subprocess.run(["bash","-eu","-c",script],cwd=ROOT,env=env,text=True,capture_output=True,check=True)
            self.assertEqual(result.stdout.strip(), "completed")


@unittest.skipUnless(shutil.which("age") and shutil.which("age-keygen"), "requires age")
class ControlDBTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)

    def test_legacy_import_once_and_concurrent_edits(self):
        legacy = self.store.root / "secrets.env"
        password = 'long secret $HOME'
        legacy.write_text('PANEL_ADMIN_PASSWORD="' + password + '"\n')
        self.store.init()
        self.assertEqual(self.store.read(True)["PANEL_ADMIN_PASSWORD"], password)
        self.assertNotIn(password.encode(), self.store.path.read_bytes())
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        legacy.write_text('PANEL_ADMIN_PASSWORD="obsolete"\n')
        self.store.init()
        self.assertEqual(self.store.read(True)["PANEL_ADMIN_PASSWORD"], password)
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            list(pool.map(self.store.update, ({"HTTPS_PORT":"444"}, {"EDGE_PROBE_PASSWORD":"new value"},
                                              {"AUDIT_DB_PASSWORD":"logger value"})))
        cfg = self.store.read(True)
        self.assertEqual([cfg[k] for k in ("HTTPS_PORT", "EDGE_PROBE_PASSWORD", "AUDIT_DB_PASSWORD")],
                         ["444","new value","logger value"])
        with self.assertRaises(ValueError):
            self.store.update({"HTTPS_PORT":"999"}, expected={"HTTPS_PORT":"443"})
        self.assertEqual(self.store.read()["HTTPS_PORT"], "444")

    def test_recover_on_clean_controller(self):
        import sqlite3
        from contextlib import closing
        self.store.init()
        expected = self.store.read(True)
        recovered = Store(self.store.root / "recovered")
        recovered.root.mkdir()
        with self.store.connect() as source, closing(sqlite3.connect(recovered.path)) as target:
            source.backup(target)
        recovered.path.chmod(0o600)
        with self.assertRaises(ValueError):
            recovered.read(True)
        shutil.copy2(self.store.identity, recovered.identity)
        self.assertEqual(recovered.read(True), expected)

    def test_ha_and_arbiter_projection(self):
        self.store.init()
        nodes = " ".join(f"n{i}.lab.test:d{i}:n{i}" for i in range(1, 6))
        self.store.update({"CLUSTER_NODES": nodes})
        self.store.ha_five()
        cfg = self.store.read()
        self.assertEqual((cfg["QUORUM_NODES"],cfg["SWFS_DEFAULT_REPLICATION"],cfg["PG_SYNC_STANDBY_COUNT"]),
                         ("n1 n2 n3 n4 n5","200","2"))
        cmd = [sys.executable, str(ROOT / "scripts/lib/config_db.py"), "--root"]
        exported = subprocess.check_output([*cmd,self.temp.name,"arbiter-export"])
        self.assertNotIn("AUDIT_DB_PASSWORD", json.loads(exported))
        arb = Store(self.store.root / "arbiter")
        def refresh():
            subprocess.run([*cmd,str(arb.root),"arbiter-import"],input=exported,check=True)
        refresh()
        with arb.connect(write=True) as db:
            db.execute("CREATE TABLE checkpoint(num INTEGER)")
            db.execute("INSERT INTO checkpoint VALUES(17)")
        refresh()
        with arb.connect() as db:
            self.assertEqual(db.execute("SELECT num FROM checkpoint").fetchone()[0],17)
            self.assertNotIn("PG_SUPERUSER_PASSWORD", arb.secrets(db))
        (self.store.root / ".cluster_installed").touch()
        with self.assertRaises(ValueError):
            self.store.ha_five()

    @unittest.skipUnless(shutil.which("htpasswd"), "requires htpasswd")
    def test_render_native_credentials(self):
        self.store.init()
        password = """p'a"ss\\word $HOME #42"""
        self.store.update({"CLUSTER_NODES":"127.0.0.2:dc1:n1 127.0.0.3:dc2:n2 127.0.0.4:dc3:n3",
                           "SFTPGO_DB_PASSWORD":password, "PG_SUPERUSER_PASSWORD":password,
                           "SWFS_ADMIN_PASSWORD":password, "SWFS_FILER_DB_PASSWORD":password})
        subprocess.run(["bash","-eu","-c",'source scripts/lib/common.sh; source scripts/lib/deploy.sh; '
                        'load_cluster_env "$CONFIG_ROOT"; render_node_configs 127.0.0.2 dc1 n1 1 existing'],
                       cwd=ROOT, env={**os.environ,"SCRIPT_DIR":str(ROOT),"CONFIG_ROOT":self.temp.name}, check=True)
        out = self.store.root / ".rendered/n1"
        sftpgo = json.loads((out / "sftpgo.json").read_text())["data_provider"]
        self.assertEqual(sftpgo["password"], password)
        escaped = password.replace(chr(92),chr(92)*2).replace(chr(39),chr(92)+chr(39))
        self.assertIn("password='" + escaped + "'", sftpgo["connection_string"])
        self.assertIn(json.dumps(password), (out / "patroni.yml").read_text())
        self.assertFalse((out / ".env").exists())
        compose = (out / "docker-compose.yml").read_text()
        self.assertNotIn("    environment:", compose)
        self.assertIn(json.dumps("-adminPassword=" + password.replace("$", "$$")), compose)

    def test_config_does_not_inherit_shell_secrets(self):
        self.store.init()
        cmd = 'source "$SCRIPT_DIR/scripts/lib/common.sh"; load_cluster_env "$CONFIG_ROOT"; ' \
              'test "$PANEL_ADMIN_PASSWORD" != spoof && test -z "$(printenv PANEL_ADMIN_PASSWORD)"'
        env = {**os.environ, "PANEL_ADMIN_PASSWORD":"spoof", "SCRIPT_DIR":str(ROOT),"CONFIG_ROOT":self.temp.name}
        subprocess.run(["bash","-eu","-c",cmd],env=env,check=True)
