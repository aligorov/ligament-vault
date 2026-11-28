import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

FILE = Path(__file__).resolve().parents[1] / "scripts/ops/client-audit.py"
spec = importlib.util.spec_from_file_location("client_audit", FILE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ClientAuditTest(unittest.TestCase):
    def test_rotation_partial_line_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "events.log"
            spool = sqlite3.connect(root / "db")
            self.addCleanup(spool.close)
            spool.executescript("CREATE TABLE cursors(file TEXT PRIMARY KEY,generation TEXT,pos INTEGER);"
                                "CREATE TABLE pending(id TEXT PRIMARY KEY,event TEXT)")
            private = "excluded-value"
            line = json.dumps({"sender":"Upload","username":"tester","message":private,
                               "virtual_path":"/work/data"}).encode()
            logs.write_bytes(b'{"sender":"config","password":"excluded-value"}\n' + line[:10])
            audit.ingest(spool, root)
            self.assertEqual(spool.execute("SELECT count(*) FROM pending").fetchone()[0], 0)
            with logs.open("ab") as out:
                out.write(line[10:] + b"\n")
            logs.rename(root / "events-old.log")
            logs.write_bytes(line + b"\n" + line + b"\n")
            audit.ingest(spool, root)
            audit.ingest(spool, root)
            rows = list(spool.execute("SELECT id,event FROM pending"))
            self.assertEqual(len({r[0] for r in rows}), 3)
            self.assertTrue(all(private not in r[1] for r in rows))
