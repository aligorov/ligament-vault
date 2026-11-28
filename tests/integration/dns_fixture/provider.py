"""Authoritative test zone. POST /record accepts one of the two known edge IPs."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import signal
import subprocess
import sys

records = json.loads(sys.argv[1])
zone_file = Path("/tmp/edge-zone.hosts")


def write_zone():
    pending = zone_file.with_suffix(".new")
    pending.write_text("".join(f"{ip} {host}\n" for host, ip in records.items()))
    pending.replace(zone_file)


class Update(BaseHTTPRequestHandler):
    def do_POST(self):
        address = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        if self.path != "/record" or address not in (records["node1.audit.test"], records["node2.audit.test"]):
            self.send_error(400)
            return
        records["files.audit.test"] = address
        write_zone()
        dns.send_signal(signal.SIGHUP)
        print(address, flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    write_zone()
    with subprocess.Popen(["dnsmasq", "--keep-in-foreground", "--no-resolv", "--no-hosts",
                           "--local=/audit.test/", "--local-ttl=1", f"--addn-hosts={zone_file}"]) as dns:
        try:
            HTTPServer(("0.0.0.0", 8053), Update).serve_forever()
        finally:
            dns.terminate()
