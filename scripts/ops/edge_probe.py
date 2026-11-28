"""Verify the three SFTPGo client protocols from the external arbiter."""
import base64
import concurrent.futures
import json
from pathlib import Path
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

USER = "__vault_probe"
HOME = "/srv/sftpgo/.edge-probe"
DESCRIPTION = "Ligament Vault edge availability probe"


def configure(admin, credentials, storage):
    password, public_key = credentials
    url = "http://127.0.0.1:8081/api/v2"
    auth = base64.b64encode(":".join(admin).encode()).decode()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def api(method, path, authorization, body=None):
        headers = {"Authorization": authorization, "Content-Type": "application/json"}
        payload = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url + path, data=payload, method=method, headers=headers)
        with opener.open(req, timeout=8) as response:
            return response.read()

    bearer = "Bearer " + json.loads(api("GET", "/token", "Basic " + auth))["access_token"]
    path = "/users/" + USER
    s3_port, s3_secret = storage
    filesystem = {"provider": 1, "s3config": {
        "bucket": "sftp-work", "key_prefix": ".vault-edge-probe/", "region": "us-east-1",
        "endpoint": f"http://127.0.0.1:{int(s3_port)}", "force_path_style": True,
        "access_key": "backup-s3-access", "access_secret": {"status": "Plain", "payload": s3_secret},
    }}
    user = {"username": USER, "description": DESCRIPTION, "status": 1, "home_dir": HOME,
            "permissions": {"/": ["list"]}, "password": password, "public_keys": [public_key],
            "filters": {"hooks": {"pre_login_disabled": True}},
            "filesystem": filesystem}
    try:
        existing = json.loads(api("GET", path, bearer))
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise
        api("POST", "/users", bearer, user)
    else:
        if (existing.get("home_dir"), existing.get("description")) != (HOME, DESCRIPTION):
            raise ValueError("Имя служебной учётной записи уже занято")
        api("PUT", path, bearer, user)


def probe(ip, domain, https_port, sftp_port, ftps_port, identity, known_hosts, password):
    options = ["curl", "--silent", "--show-error", "--fail", "--noproxy", "*",
               "--connect-timeout", "3", "--max-time", "8"]
    local_ca = Path(__file__).resolve().parents[2] / "prometheus/edge-client-ca.pem"
    if local_ca.is_file():
        options.extend(["--cacert", str(local_ca), "--capath", "/etc/ssl/certs"])

    def web():
        result = subprocess.run([*options, "--resolve", f"{domain}:{https_port}:{ip}",
                                 "--write-out", "%{response_code}", "--output", "/dev/null",
                                 f"https://{domain}:{https_port}/web/client/login"],
                                check=True, stdout=subprocess.PIPE, timeout=9)
        if result.stdout != b"200":
            raise ValueError("Страница входа WebClient не вернула HTTP 200")

    def ftp():
        # Follow the PASV reply and require a protected data channel.
        config = "user = " + json.dumps(USER + ":" + password) + "\n"
        subprocess.run([*options, "--config", "-", "--resolve", f"{domain}:{ftps_port}:{ip}",
                        "--ssl-reqd", "--ftp-pasv", "--disable-epsv", "--no-ftp-skip-pasv-ip",
                        "--list-only", "--output", "/dev/null", f"ftp://{domain}:{ftps_port}/"],
                       input=config.encode(), check=True, timeout=9)

    def sftp():
        subprocess.run(["sftp", "-q", "-b", "-", "-P", str(sftp_port), "-i", identity,
                        "-oBatchMode=yes", "-oIdentitiesOnly=yes", "-oConnectTimeout=3",
                        "-oStrictHostKeyChecking=yes", "-oHostKeyAlias=vault-edge",
                        "-oHostKeyAlgorithms=ssh-ed25519", "-oGlobalKnownHostsFile=/dev/null",
                        "-oUserKnownHostsFile=" + known_hosts, USER + "@" + ip],
                       input=b"ls -1 /\n", stdout=subprocess.DEVNULL, check=True, timeout=9)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        pending = {pool.submit(check): label for label, check in
                   (("WebClient", web), ("FTPS PASV", ftp), ("SFTP", sftp))}
        for future in concurrent.futures.as_completed(pending):
            try:
                future.result()
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                raise RuntimeError(f"{pending[future]} на {ip}: {type(exc).__name__}") from None


if __name__ == "__main__":
    try:
        if sys.argv[1] == "credentials":
            sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
            from config_db import Store
            store = Store(sys.argv[2])
            values = store.read(include_secrets=True)
            password = values.get("EDGE_PROBE_PASSWORD", "")
            if not password:
                password = secrets.token_urlsafe(36)
                store.update({"EDGE_PROBE_PASSWORD": password})
            json.dump([[values["SFTPGO_ADMIN_USERNAME"], values["SFTPGO_ADMIN_PASSWORD"]],
                       [password, sys.argv[3]], [values["SWFS_S3_PORT"], values["SWFS_S3_SECRET_KEY_BACKUP"]]],
                      sys.stdout)
        elif sys.argv[1] == "configure":
            admin, probe_credentials, storage = json.load(sys.stdin)
            configure(admin, probe_credentials, storage)
        elif sys.argv[1] == "probe":
            password = sys.stdin.read().rstrip("\n")
            if not password:
                raise ValueError("В конфигурационной БД нет пароля служебной пробы")
            probe(*sys.argv[2:], password)
        else:
            raise ValueError("Неизвестная операция проверки")
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
