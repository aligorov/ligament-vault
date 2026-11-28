"""Run with Python 3, Docker, OpenSSL and ssh-keygen. Prints JSON evidence to stdout.

Two real SFTPGo edges use a shared SeaweedFS server. The restricted SSH commands
for the etcd lease and fencing are recorded locally. All configuration and keys
belong to an isolated network and temporary directory created by this test.
"""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).with_name("dns_fixture")
DOMAIN = "files.audit.test"
NODE1, NODE2 = "node1.audit.test", "node2.audit.test"


def run(*command, data=None, check=True, timeout=60):
    result = subprocess.run(command, input=data, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{command[:2]} failed ({result.returncode}): {result.stderr.decode(errors='replace')[-1200:]}")
    return result


def docker(*args, **options):
    return run("docker", *args, **options)


def inside(container, *args, **options):
    return docker("exec", "-i", container, *args, **options)


def wait_for(description, operation, timeout=75):
    end = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < end:
        try:
            if operation():
                return
        except (RuntimeError, ValueError, IndexError) as exc:
            last_error = str(exc)
        time.sleep(0.8)
    raise RuntimeError(f"Timed out waiting for {description}. {last_error}")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Lab:
    def __init__(self, directory):
        self.directory = directory
        self.runtime = directory / "runtime"
        self.prefix = "lv-dns-" + secrets.token_hex(6)
        self.network = self.prefix + "-net"
        self.image = self.prefix + ":test"
        self.containers = []
        self.created_network = False
        self.images = json.loads((ROOT / "configs/control-defaults.json").read_text())["images"]

    def prepare(self):
        docker("build", "-t", self.image, str(FIXTURE), timeout=600)
        for key in ("SFTPGO_IMAGE", "SEAWEEDFS_IMAGE"):
            image = self.images[key]
            if docker("image", "inspect", image, check=False).returncode:
                docker("pull", image, timeout=600)
        docker("network", "create", "--internal", self.network)
        self.created_network = True
        subnet = docker("network", "inspect", self.network, "-f", "{{(index .IPAM.Config 0).Subnet}}")
        network = ipaddress.ip_network(subnet.stdout.decode().strip())
        self.dns, self.first, self.second, self.store, self.client = [str(network[i]) for i in (10, 11, 12, 14, 16)]

    def start(self, name, image, command, *, address=None, namespace=None, volumes=()):
        name = f"{self.prefix}-{name}"
        network = ["--network", "container:" + namespace] if namespace else [
            "--network", self.network, "--ip", address, "--dns", self.dns]
        self.containers.append(name)
        docker("run", "--pull=never", "-d", "--name", name, *network, "-v", str(self.directory) + ":/lab:ro",
               *volumes, image, *command)
        return name

    def set_resolver(self, name):
        inside(name, "sh", "-c", 'printf "nameserver %s\\noptions timeout:1 attempts:1\\n" "$1" >/etc/resolv.conf',
               "resolve", self.dns)

    def cleanup(self):
        for name in reversed(self.containers):
            docker("rm", "-fv", name, check=False)
        if self.created_network:
            docker("network", "rm", self.network, check=False)
        docker("image", "rm", self.image, check=False)


def prepare_arbiter(lab):
    runtime = lab.runtime
    parts = ("configs/control-defaults.json", "scripts/lib/config_db.py", "scripts/lib/node_address.py",
             "scripts/lib/common.sh", "scripts/lib/deploy.sh", "scripts/ops/edge_probe.py",
             "scripts/ops/arbiter_state.py", "scripts/ops/dns-failover-arbiter.sh")
    for part in parts:
        dest = runtime / part
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / part, dest)
    (runtime / ".ssh").mkdir()
    (runtime / "prometheus").mkdir()
    for path in (lab.directory / "hostkey", runtime / ".ssh/id_ed25519"):
        run("ssh-keygen", "-q", "-t", "ed25519", "-f", path, "-N", "")
    # Only this temporary directory is shared with the unprivileged SFTPGo process.
    (lab.directory / "hostkey").chmod(0o644)
    (runtime / ".ssh/edge_known_hosts").write_text("vault-edge " + (lab.directory / "hostkey.pub").read_text())
    tls = lab.directory / "tls.crt"
    key = lab.directory / "tls.key"
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key, "-out", tls,
        "-subj", "/CN=" + DOMAIN, "-addext", "subjectAltName=DNS:" + DOMAIN)
    key.chmod(0o644)
    shutil.copy(tls, runtime / "prometheus/edge-client-ca.pem")
    hook = runtime / "dns-hook"
    hook.write_text('#!/bin/sh\nexec curl -fsS --noproxy "*" --max-time 3 --data-binary "$2" http://zone.audit.test:8053/record\n')
    hook.chmod(0o700)
    (runtime / "daemon").write_text(
        'source /vault/scripts/ops/dns-failover-arbiter.sh\n'
        'arbiter_ssh() { printf "%s %s\\n" "$@" >> /vault/simulated-ssh; }\n'
        'main --daemon\n')


def start_storage(lab, runner, reader_secret, writer_secret):
    config = {"identities": [
        {"name": "reader", "credentials": [{"accessKey": "backup-s3-access", "secretKey": reader_secret}],
         "actions": ["Read", "List"]},
        {"name": "files", "credentials": [{"accessKey": "test-file-access", "secretKey": writer_secret}],
         "actions": ["Read", "List", "Write", "Admin"]}]}
    (lab.directory / "s3.json").write_text(json.dumps(config))
    storage = lab.start("store", lab.images["SEAWEEDFS_IMAGE"], [
        "server", "-ip=" + lab.store, "-ip.bind=0.0.0.0", "-dir=/data", "-master.volumeSizeLimitMB=10",
        "-volume.max=2", "-s3", "-s3.config=/lab/s3.json"], address=lab.store)

    def leader():
        reply = inside(runner, "curl", "-fsS", "--max-time", "3", f"http://{lab.store}:9333/cluster/status")
        return json.loads(reply.stdout).get("Leader")

    wait_for("SeaweedFS master", leader)
    inside(storage, "weed", "shell", "-master=" + lab.store + ":9333", "-filer=" + lab.store + ":8888",
           data=b"s3.bucket.create -name=sftp-work\n")
    return storage


def start_edges(lab, reader_secret, writer_secret, probe_password, client_password):
    image = lab.images["SFTPGO_IMAGE"]
    result = docker("run", "--rm", "--network", "none", "--entrypoint", "cat", image, "/etc/sftpgo/sftpgo.json")
    config = json.loads(result.stdout)
    config["sftpd"]["host_keys"] = ["/lab/hostkey"]
    ftp = config["ftpd"]
    ftp["bindings"][0].update(port=2121, tls_mode=1)
    ftp.update(certificate_file="/lab/tls.crt", certificate_key_file="/lab/tls.key",
               passive_port_range={"start": 50020, "end": 50029})
    http = config["httpd"]
    http["bindings"][0].update(port=8081, address="127.0.0.1", enable_web_admin=True, enable_rest_api=True)
    http["bindings"].append(dict(http["bindings"][0], port=8443, address="", enable_web_admin=False,
                                 enable_rest_api=False, enable_web_client=True, enable_https=True,
                                 certificate_file="/lab/tls.crt", certificate_key_file="/lab/tls.key"))
    for key, subdir in (("templates_path", "templates"), ("static_files_path", "static"), ("openapi_path", "openapi")):
        http[key] = "/usr/share/sftpgo/" + subdir
    admin_password = secrets.token_hex(24)
    s3 = {"bucket": "sftp-work", "key_prefix": "client-fixture/", "region": "us-east-1",
          "endpoint": "http://127.0.0.1:8333", "force_path_style": True, "access_key": "test-file-access",
          "access_secret": {"status": "Plain", "payload": writer_secret}}
    users = [{"username": "testclient", "password": client_password, "status": 1, "home_dir": "/srv/sftpgo/test",
              "permissions": {"/": ["*"]}, "filesystem": {"provider": 1, "s3config": s3}}]
    admin = {"status": 1, "username": "operator", "password": admin_password, "permissions": ["*"]}
    (lab.directory / "load.json").write_text(json.dumps({"version": 16, "admins": [admin], "users": users}))
    credentials = json.dumps([["operator", admin_password],
                              [probe_password, (lab.runtime / ".ssh/id_ed25519.pub").read_text().strip()],
                              [8333, reader_secret]]).encode()
    nodes = []
    for index, (fqdn, address) in enumerate(((NODE1, lab.first), (NODE2, lab.second)), 1):
        node = lab.start(f"node{index}", lab.image, ["socat", "TCP-LISTEN:8333,bind=127.0.0.1,reuseaddr,fork",
                                                     f"TCP:{lab.store}:8333"], address=address)
        lab.set_resolver(node)
        ftp["bindings"][0]["passive_host"] = fqdn
        path = f"node{index}.json"
        (lab.directory / path).write_text(json.dumps(config))
        edge = lab.start(f"edge{index}", image, ["sftpgo", "serve", "-c", "/var/lib/sftpgo",
                         "--config-file", "/lab/" + path, "--log-file-path", "", "--log-level", "info",
                         "--loaddata-from", "/lab/load.json"], namespace=node)
        wait_for(f"{fqdn} client probe account", lambda: inside(
            node, "python3", "/lab/runtime/scripts/ops/edge_probe.py", "configure", data=credentials).returncode == 0)
        nodes.append((edge, node))
    return nodes


def verify(lab):
    prepare_arbiter(lab)
    reader_secret, writer_secret, probe_password, client_password = (secrets.token_hex(24) for _ in range(4))
    records = {DOMAIN: lab.first, NODE1: lab.first, NODE2: lab.second, "zone.audit.test": lab.dns}
    shutil.copy(FIXTURE / "provider.py", lab.directory / "provider.py")
    provider = lab.start("dns", lab.image, ["python3", "/lab/provider.py", json.dumps(records)], address=lab.dns)
    runner = lab.start("client", lab.image, ["sleep", "infinity"], address=lab.client,
                       volumes=["-v", str(lab.runtime) + ":/vault"])
    lab.set_resolver(runner)

    def resolved():
        return inside(runner, "getent", "ahostsv4", DOMAIN).stdout.decode().split()[0]

    wait_for("initial A record", lambda: resolved() == lab.first)
    settings = {"CLUSTER_NODES": f"{NODE1}:dc1:n1 {NODE2}:dc2:n2", "DOMAIN": DOMAIN, "DNS_TTL": "1",
                "DNS_UPDATE_HOOK": "/vault/dns-hook", "DNS_PROVIDER": "custom", "SFTP_PORT": "2022",
                "HTTPS_PORT": "8443", "FTPS_PORT": "2121", "EDGE_PROBE_PASSWORD": probe_password}
    inside(runner, "python3", "-c", 'import json,sys; sys.path.insert(0,"/vault/scripts/lib"); '
           'from config_db import Store; s=Store("/vault"); s.init(migrate=False); s.update(json.load(sys.stdin))',
           data=json.dumps(settings).encode())
    storage = start_storage(lab, runner, reader_secret, writer_secret)
    nodes = start_edges(lab, reader_secret, writer_secret, probe_password, client_password)
    (lab.directory / "curl.cfg").write_text("user = " + json.dumps("testclient:" + client_password) + "\n")
    curl = ["curl", "--silent", "--show-error", "--fail", "--noproxy", "*", "--config", "/lab/curl.cfg",
            "--cacert", "/lab/tls.crt", "--ssl-reqd", "--ftp-pasv", "--disable-epsv", "--no-ftp-skip-pasv-ip",
            "--connect-timeout", "3", "--max-time", "12"]
    url = f"ftp://{DOMAIN}:2121/file.bin"
    data = os.urandom(65536)
    (lab.directory / "payload").write_bytes(data)
    inside(runner, *curl, "--upload-file", "/lab/payload", url)
    require(inside(runner, *curl, url).stdout == data, "Initial FTPS read differs from the uploaded bytes")
    docker("exec", "-d", runner, "sh", "-c", "exec bash /vault/daemon >/vault/daemon.log 2>&1")

    def confirmed(node, ip):
        read = inside(runner, "python3", "/vault/scripts/ops/arbiter_state.py", "/vault/control.sqlite3", "read")
        return read.stdout.decode().strip().split("|")[:3] == [node, ip, "0"]

    wait_for("initial publication by the arbiter", lambda: confirmed(NODE1, lab.first))
    started = time.monotonic()
    docker("kill", *nodes[0])
    interrupted = inside(runner, *curl, url, check=False)
    require(interrupted.returncode != 0 and resolved() == lab.first, "Expected a failed request through the old record")
    wait_for("automatic DNS failover", lambda: confirmed(NODE2, lab.second) and resolved() == lab.second, timeout=150)
    require(inside(runner, *curl, url).stdout == data, "Recovered FTPS read differs from the original bytes")
    first_read = round(time.monotonic() - started, 3)
    new_data = os.urandom(32768)
    (lab.directory / "payload2").write_bytes(new_data)
    inside(runner, *curl, "--upload-file", "/lab/payload2", url + ".new")
    require(inside(runner, *curl, url + ".new").stdout == new_data, "New write/read failed after failover")
    probe = ["python3", "/vault/scripts/ops/edge_probe.py", "probe", lab.second, DOMAIN, "8443", "2022", "2121",
             "/vault/.ssh/id_ed25519", "/vault/.ssh/edge_known_hosts"]
    inside(runner, *probe, data=probe_password.encode())
    docker("kill", storage)
    storage_down = inside(runner, *probe, data=probe_password.encode(), check=False)
    require(storage_down.returncode != 0, "The probe accepted an edge with unavailable S3")
    publications = docker("logs", provider).stdout.decode().splitlines()
    require(publications == [lab.first, lab.second], "Unexpected authority publication history")
    commands = inside(runner, "cat", "/vault/simulated-ssh").stdout.decode().splitlines()
    require(f"{NODE1} fence-edge" in commands, "The arbiter never requested fencing")
    return {"fqdn": DOMAIN, "ttl_s": 1, "published": publications, "ftps_error_after_stop": interrupted.returncode,
            "original_bytes": len(data), "sha256_before_and_after": hashlib.sha256(data).hexdigest(),
            "seconds_to_verified_ftps_read": first_read, "new_bytes_verified": len(new_data),
            "s3_unavailable_probe_exit": storage_down.returncode, "simulated_ssh_commands": commands,
            "topology": "two real SFTPGo edges with local test admin DBs and one shared SeaweedFS server"}


if __name__ == "__main__":
    try:
        with tempfile.TemporaryDirectory(prefix="lv-dns-") as temp:
            # Non-root SFTPGo reads the certs and fixture data through this child bind mount.
            directory = Path(temp) / "fixture"
            directory.mkdir(mode=0o755)
            lab = Lab(directory)
            try:
                lab.prepare()
                result = verify(lab)
                print(json.dumps(result, indent=2))
            finally:
                lab.cleanup()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        sys.exit(str(exc))
