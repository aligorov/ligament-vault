"""Render private native configuration and remove profile gates for this node's roles."""
import json
from pathlib import Path
import re
import subprocess
import sys

from config_db import Store


def render(root, output, name, profiles):
    cfg = Store(root).read(True)
    out = Path(output)
    compose = out / "docker-compose.yml"
    active = set(profiles.split(","))
    compose.write_text(re.sub(r'^    profiles: \["([^"]+)"\]\n',
                              lambda m: "" if m[1] in active else m[0], compose.read_text(), flags=re.M))
    admin = cfg["SFTPGO_ADMIN_USERNAME"]
    hashed = subprocess.run(["htpasswd", "-niBC", "10", admin], input=cfg["SFTPGO_ADMIN_PASSWORD"] + "\n",
                            text=True, capture_output=True, check=True).stdout.strip().partition(":")[2]
    if not hashed.startswith("$2"):
        raise ValueError("Не удалось создать bcrypt-хеш администратора")
    # SFTPGo recognizes the Go bcrypt prefix when importing an existing hash.
    hashed = "$2a$" + hashed[4:]
    (out / "sftpgo-bootstrap.json").write_text(json.dumps({"version":16, "admins":[
        {"username":admin, "password":hashed, "status":1, "permissions":["*"]}]}))
    (out / "hooks/ligament-2fa.json").write_text(json.dumps(
        {k:v for k,v in cfg.items() if k.startswith("LIGAMENT_2FA_") or k == "CLUSTER_SLUG"}))
    (out / "client-audit.json").write_text(json.dumps({"node":name, "postgres":{
        "host":"127.0.0.1", "port":cfg["HAPROXY_PG_PORT"], "user":"client_logger", "dbname":"postgres",
        "password":cfg["AUDIT_DB_PASSWORD"], "sslmode":"verify-full", "sslrootcert":"/certs/ca.crt",
        "sslcert":"/certs/pg-client.crt", "sslkey":"/certs/pg-client.key", "connect_timeout":3,
        "options":"-c statement_timeout=5000"}}))


if __name__ == "__main__":
    render(*sys.argv[1:])
