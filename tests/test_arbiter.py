"""DNS publication and PostgreSQL failback checks (localhost only)."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from contextlib import closing
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "scripts/ops/arbiter_state.py"


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        candidate = self.rfile.read(int(self.headers["Content-Length"])).decode()
        self.server.requests.append(candidate)
        if self.server.code == 200:
            self.server.record = candidate
        self.send_response(self.server.code)
        self.end_headers()

    def log_message(self, *args):
        pass


class DNSArbiterTests(unittest.TestCase):
    def test_pending_publication_reconciles_after_interrupted_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            db = directory / "control.sqlite3"
            sqlite3.connect(db).close()
            old, new = "127.0.0.2", "127.0.0.3"
            subprocess.run([sys.executable, STATE, db, "write", old, old, "3", "90", "0", "0"], check=True)
            subprocess.run([sys.executable, STATE, db, "pending"], check=True)
            # The provider changed the record before the arbiter lost power. The old edge then recovered.
            record = directory / "record"
            record.write_text(new)
            tick = """
                source scripts/ops/dns-failover-arbiter.sh
                CONFIG_ROOT=$1
                CLUSTER_NODES="127.0.0.2:dc1:one 127.0.0.3:dc2:two"
                probe_edge_node() { return 0; }
                arbiter_ssh() { return 0; }
                update_dns_provider() { echo "$1" > "$CONFIG_ROOT/record"; echo ok >> "$CONFIG_ROOT/count"; }
                run_once
                run_once
            """
            subprocess.run(["bash", "-c", tick, "arbiter", directory], cwd=ROOT, check=True, capture_output=True)
            self.assertEqual(record.read_text().strip(), old)
            self.assertEqual((directory / "count").read_text().splitlines(), ["ok"])

    def test_failback_requires_primary_timeline_and_replay_position(self):
        check = """
            source scripts/ops/dns-failover-arbiter.sh
            get_node_ips() { printf '%s\\n' one.test two.test; }
            curl() {
                case "${!#}" in
                    https://one.test:8008/primary) return 1 ;;
                    https://two.test:8008/primary) return 0 ;;
                    https://two.test:8008/patroni) echo '{"role":"primary","state":"running","timeline":2,"xlog":{"location":100}}' ;;
                    https://one.test:8008/patroni) printf '{"role":"replica","state":"running","timeline":%s,"xlog":{"received_location":%s,"replayed_location":%s}}' "$timeline" "$position" "$position" ;;
                    *) return 1 ;;
                esac
            }
            timeline=$1 position=$2
            replica_ready one.test
        """
        for timeline, position, expected in ((2, 100, 0), (2, 98, 1), (1, 100, 1)):
            with self.subTest(timeline=timeline, position=position):
                result = subprocess.run(["bash", "-c", check, "arbiter", str(timeline), str(position)],
                                        cwd=ROOT, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_http_failure_and_recovery_across_restart(self):
        with tempfile.TemporaryDirectory() as td, ThreadingHTTPServer(("127.0.0.1", 0), Provider) as api:
            directory = Path(td)
            db = directory / "control.sqlite3"
            sqlite3.connect(db).close()
            old, new = "127.0.0.2", "127.0.0.3"
            api.record, api.code, api.requests = old, 503, []
            thread = threading.Thread(target=api.serve_forever, daemon=True)
            thread.start()
            try:
                subprocess.run([sys.executable, STATE, db, "write", old, old, "2", "90", "0", "0"], check=True)
                hook = directory / "dns-hook"
                hook.write_text(f'#!/bin/sh\nexec curl -fsS --noproxy "*" --data-binary "$2" http://127.0.0.1:{api.server_port}/record\n')
                hook.chmod(0o700)
                tick = """
                    source scripts/ops/dns-failover-arbiter.sh
                    CONFIG_ROOT=$1
                    DOMAIN=files.audit.test
                    CLUSTER_NODES="127.0.0.2:dc1:one 127.0.0.3:dc2:two"
                    DNS_PROVIDER=test
                    DNS_UPDATE_HOOK=$1/dns-hook
                    probe_edge_node() { [[ "$1" == 127.0.0.3 ]]; }
                    arbiter_ssh() { echo "$2" >> "$CONFIG_ROOT/ssh"; }
                    run_once
                """
                def run_tick():
                    return subprocess.run(["bash", "-c", tick, "audit", directory], cwd=ROOT, capture_output=True)
                self.assertNotEqual(run_tick().returncode, 0)
                self.assertEqual(api.record, old)
                with closing(sqlite3.connect(db)) as conn, conn:
                    state = conn.execute("SELECT active,ip,failures,switched FROM edge_state").fetchone()
                self.assertEqual(state, (old, old, 3, 90))
                self.assertFalse((directory / "ssh").exists())
                api.code = 200
                result = run_tick()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(api.record, new)
                with closing(sqlite3.connect(db)) as conn, conn:
                    state = conn.execute("SELECT active,ip,failures FROM edge_state").fetchone()
                self.assertEqual(state, (new, new, 0))
                self.assertEqual(api.requests, [new, new])
                self.assertIn("fence-edge", (directory / "ssh").read_text())
            finally:
                api.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
