#!/usr/bin/env python3
"""
Ligament Vault — Единая HTTPS Веб-панель управления кластером (:8443)
Без внешних зависимостей (чистый Python 3 stdlib + TLS + Rate-Limit + CSRF).
"""

import hashlib
import hmac
import http.cookies
import json
import os
import re
import secrets
import shlex
import socket
import ssl
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WEB_DIR = os.path.abspath(os.path.dirname(__file__))
CONFIG_ROOT = os.environ.get("CONFIG_ROOT", REPO_DIR)
STATE_DIR = os.path.join(CONFIG_ROOT, ".state", "panel")

SESSIONS = {}  # token -> {"csrf": str, "exp": float}
RATE_LIMIT = {}  # ip -> [timestamps]
TASKS = {}  # task_id -> {"cmd": str, "status": str, "rc": int|None, "log": list[str], "started": float}
LOCK = threading.Lock()

SESSION_TTL = 43200  # 12 часов
MAX_FAILED_LOGINS = 10
FAIL_WINDOW_SEC = 300


def parse_env_text(text):
    data = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        try:
            parts = shlex.split(line, comments=True)
            if parts and "=" in parts[0]:
                k, v = parts[0].split("=", 1)
                data[k] = v
        except Exception:
            no_comment = line.split("#", 1)[0].strip()
            if "=" in no_comment:
                k, v = no_comment.split("=", 1)
                data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def read_env_dict(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return parse_env_text(f.read())


def read_secrets_dict():
    plain = os.path.join(CONFIG_ROOT, "secrets.env")
    enc = os.path.join(CONFIG_ROOT, "secrets.env.age")
    if os.path.exists(plain):
        return read_env_dict(plain)
    if os.path.exists(enc):
        age_key = os.environ.get(
            "AGE_KEY_FILE",
            os.environ.get("SOPS_AGE_KEY_FILE", os.path.expanduser("~/.config/ligament/age.key")),
        )
        if os.path.exists(age_key):
            res = subprocess.run(["age", "-d", "-i", age_key, enc], capture_output=True, text=True, timeout=5)
            if res.returncode == 0:
                return parse_env_text(res.stdout)
    return {}


def get_admin_credentials():
    cenv = read_env_dict(os.path.join(CONFIG_ROOT, "cluster.env"))
    senv = read_secrets_dict()
    user = os.environ.get("PANEL_ADMIN_USER") or cenv.get("SFTPGO_ADMIN_USERNAME") or "admin"
    pw = os.environ.get("PANEL_ADMIN_PASSWORD") or senv.get("SFTPGO_ADMIN_PASSWORD") or ""
    return user, pw


def _escape_env_value(val):
    return (
        str(val)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("`", "\\`")
    )


def update_env_file(path, updates):
    with LOCK:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        text = open(path, "r", encoding="utf-8").read() if os.path.exists(path) else ""
        for k, v in updates.items():
            if v is None:
                continue
            safe_v = _escape_env_value(v)
            newline = f'{k}="{safe_v}"'
            if re.search(rf"^{re.escape(k)}=.*$", text, flags=re.M):
                text = re.sub(rf"^{re.escape(k)}=.*$", newline, text, flags=re.M)
            else:
                text += ("\n" if text and not text.endswith("\n") else "") + newline + "\n"
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)


def update_secrets(updates):
    if not updates:
        return
    plain = os.path.join(CONFIG_ROOT, "secrets.env")
    enc = os.path.join(CONFIG_ROOT, "secrets.env.age")
    age_key = os.environ.get(
        "AGE_KEY_FILE",
        os.environ.get("SOPS_AGE_KEY_FILE", os.path.expanduser("~/.config/ligament/age.key")),
    )
    with LOCK:
        if os.path.exists(enc) and os.path.exists(age_key):
            res = subprocess.run(["age", "-d", "-i", age_key, enc], capture_output=True, text=True, timeout=5)
            if res.returncode != 0:
                raise RuntimeError(f"Не удалось расшифровать secrets.env.age: {(res.stderr or '').strip()}")
            text = res.stdout
            for k, v in updates.items():
                if v is None or v == "":
                    continue
                safe_v = _escape_env_value(v)
                newline = f'{k}="{safe_v}"'
                if re.search(rf"^{re.escape(k)}=.*$", text, flags=re.M):
                    text = re.sub(rf"^{re.escape(k)}=.*$", newline, text, flags=re.M)
                else:
                    text += ("\n" if text and not text.endswith("\n") else "") + newline + "\n"
            rec = subprocess.check_output(["age-keygen", "-y", age_key], text=True, timeout=5).strip()
            p = subprocess.run(["age", "-r", rec, "-o", enc + ".tmp"], input=text, capture_output=True, text=True, timeout=5)
            if p.returncode != 0:
                raise RuntimeError(f"Не удалось перешифровать secrets.env.age: {(p.stderr or '').strip()}")
            os.chmod(enc + ".tmp", 0o600)
            os.replace(enc + ".tmp", enc)
            return

    filtered = {k: v for k, v in updates.items() if v is not None and v != ""}
    if filtered:
        update_env_file(plain, filtered)


def ensure_tls_cert():
    cenv = read_env_dict(os.path.join(CONFIG_ROOT, "cluster.env"))
    domain = cenv.get("DOMAIN", "")
    le_crt = os.path.join(CONFIG_ROOT, ".ssl", "certificates", f"{domain}.crt")
    le_key = os.path.join(CONFIG_ROOT, ".ssl", "certificates", f"{domain}.key")
    if domain and os.path.exists(le_crt) and os.path.exists(le_key):
        return le_crt, le_key

    os.makedirs(STATE_DIR, exist_ok=True)
    crt = os.path.join(STATE_DIR, "panel.crt")
    key = os.path.join(STATE_DIR, "panel.key")
    if os.path.exists(crt) and os.path.exists(key):
        return crt, key

    sans = ["DNS:localhost", "IP:127.0.0.1"]
    if domain:
        sans.append(f"DNS:{domain}")
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        local_ip = s.getsockname()[0]
        s.close()
        sans.append(f"IP:{local_ip}")
    except Exception:
        pass

    subprocess.run(
        [
            "openssl", "req", "-x509", "-nodes", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-days", "825", "-keyout", key, "-out", crt,
            "-subj", "/CN=Ligament Vault Control Panel/O=Ligament",
            "-addext", f"subjectAltName={','.join(dict.fromkeys(sans))}",
        ],
        check=True,
        capture_output=True,
    )
    os.chmod(key, 0o600)
    return crt, key


def get_orchestrator_pubkey():
    if os.environ.get("ORCHESTRATOR_PUBKEY"):
        return os.environ["ORCHESTRATOR_PUBKEY"].strip()
    for candidate in ("/root/.ssh/id_ed25519.pub", os.path.expanduser("~/.ssh/id_ed25519.pub")):
        if os.path.exists(candidate):
            return open(candidate, "r", encoding="utf-8").read().strip()
    return ""


def bootstrap_remote_vps_ssh(ip, ssh_port, root_password, pubkey):
    """Разово подключается к новому VPS по паролю (или существующему ключу),
    прописывает SSH-ключ оркестратора и ставит Docker при необходимости."""
    qpub = shlex.quote(pubkey)
    remote_cmd = (
        f"mkdir -p /root/.ssh && chmod 700 /root/.ssh && "
        f"touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && "
        f"(grep -Fqx {qpub} /root/.ssh/authorized_keys || echo {qpub} >> /root/.ssh/authorized_keys) && "
        f"(command -v docker >/dev/null 2>&1 || (curl -fsSL https://get.docker.com | sh && systemctl enable --now docker)) && "
        f"apt-get clean >/dev/null 2>&1 || true && "
        f"echo VPS_BOOTSTRAP_OK"
    )
    base_ssh = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10", "-p", str(ssh_port), f"root@{ip}", remote_cmd,
    ]
    # 1. Сначала пробуем без пароля (если ключ уже был добавлен)
    r_key = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8", "-p", str(ssh_port), f"root@{ip}", remote_cmd],
        capture_output=True, text=True, timeout=180,
    )
    if r_key.returncode == 0 and "VPS_BOOTSTRAP_OK" in r_key.stdout:
        return True, "Узел подключен по SSH-ключу, Docker готов"

    if not root_password:
        return False, "Ключ еще не прописан на целевом VPS — укажите пароль root для автоматического подключения"

    # 2. Через sshpass -e (пароль передается через env в памяти, не светится в ps aux!)
    if shutil_which("sshpass"):
        r_pw = subprocess.run(
            ["sshpass", "-e", *base_ssh],
            env={**os.environ, "SSHPASS": root_password},
            capture_output=True, text=True, timeout=180,
        )
        if r_pw.returncode == 0 and "VPS_BOOTSTRAP_OK" in r_pw.stdout:
            return True, "SSH-ключ автоматически установлен по паролю, Docker готов"
        return False, (r_pw.stderr or r_pw.stdout or "Ошибка подключения по SSH").strip()

    # 3. Fallback через stdlib pty (если sshpass не установлен)
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", base_ssh)
    output = b""
    pw_sent = False
    deadline = time.time() + 180
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            output += chunk
            low = output.lower()
            if (b"password:" in low) and not pw_sent:
                os.write(fd, (root_password + "\n").encode("utf-8"))
                pw_sent = True
        except OSError:
            break
    os.close(fd)
    _, status = os.waitpid(pid, 0)
    decoded = output.decode("utf-8", "replace")
    if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0 and "VPS_BOOTSTRAP_OK" in decoded:
        return True, "SSH-ключ установлен, Docker готов"
    return False, "Не удалось подключиться по SSH (проверьте IP, порт и пароль root)"


def shutil_which(cmd):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        full = os.path.join(p, cmd)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


def start_async_task(label, argv):
    task_id = uuid.uuid4().hex[:12]
    with LOCK:
        for t in TASKS.values():
            if t["status"] == "running":
                return None, "Другая задача уже выполняется — дождитесь ее завершения в консоли"
        TASKS[task_id] = {
            "id": task_id,
            "label": label,
            "status": "running",
            "rc": None,
            "log": [f"▶ Запуск: {label} ({' '.join(argv)})"],
            "started": time.time(),
        }

    def runner():
        env = {**os.environ, "CONFIG_ROOT": CONFIG_ROOT}
        try:
            proc = subprocess.Popen(
                argv,
                cwd=REPO_DIR,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                clean = re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip("\n"))
                with LOCK:
                    TASKS[task_id]["log"].append(clean)
            rc = proc.wait()
            with LOCK:
                TASKS[task_id]["rc"] = rc
                TASKS[task_id]["status"] = "success" if rc == 0 else "failed"
                TASKS[task_id]["log"].append(f"■ Завершено с кодом {rc}")
        except Exception as exc:
            with LOCK:
                TASKS[task_id]["rc"] = 1
                TASKS[task_id]["status"] = "failed"
                TASKS[task_id]["log"].append(f"[ERROR] {exc}")

    threading.Thread(target=runner, daemon=True).start()
    return task_id, None


class PanelHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, payload, extra_headers=None):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def read_body_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 1_048_576:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def check_session(self, require_csrf=False):
        auth_hdr = self.headers.get("Authorization", "")
        if auth_hdr.startswith("Bearer "):
            _, admin_pw = get_admin_credentials()
            if admin_pw and hmac.compare_digest(auth_hdr[7:].strip(), admin_pw):
                return True

        cookie_hdr = self.headers.get("Cookie", "")
        jar = http.cookies.SimpleCookie()
        jar.load(cookie_hdr)
        sid = jar["lv_session"].value if "lv_session" in jar else ""
        now = time.time()
        with LOCK:
            sess = SESSIONS.get(sid)
            if not sess or sess["exp"] < now:
                SESSIONS.pop(sid, None)
                return False
            if require_csrf:
                csrf = self.headers.get("X-CSRF-Token", "")
                if not csrf or not hmac.compare_digest(csrf, sess["csrf"]):
                    return False
            return True

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            html = open(os.path.join(WEB_DIR, "index.html"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
            self.wfile.write(html)
            return

        if path == "/api/v1/health":
            self.send_json(200, {"ok": True})
            return

        if path == "/api/v1/auth/session":
            if not self.check_session():
                self.send_json(401, {"authenticated": False})
                return
            jar = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
            sid = jar["lv_session"].value if "lv_session" in jar else ""
            csrf = SESSIONS.get(sid, {}).get("csrf", "")
            self.send_json(200, {"authenticated": True, "csrf": csrf})
            return

        if not self.check_session():
            self.send_json(401, {"error": "Требуется авторизация"})
            return

        if path == "/api/v1/overview":
            cenv = read_env_dict(os.path.join(CONFIG_ROOT, "cluster.env"))
            installed = os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed"))
            nodes_raw = cenv.get("CLUSTER_NODES", "")
            health = {"nodes": [], "swfs_replication_healthy": True, "ssl_days_remaining": "N/A", "last_backup": "N/A", "warnings": 0, "errors": 0}
            qs = parse_qs(parsed.query)
            if installed and "FIXME" not in nodes_raw and qs.get("live", ["0"])[0] == "1":
                res = subprocess.run(
                    [os.path.join(REPO_DIR, "ligactl"), "status", "--json"],
                    cwd=REPO_DIR,
                    env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT},
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                for line in reversed(res.stdout.splitlines()):
                    if line.startswith("{"):
                        try:
                            health = json.loads(line)
                        except Exception:
                            pass
                        break
            else:
                for entry in nodes_raw.split():
                    parts = entry.split(":")
                    if len(parts) >= 3:
                        health["nodes"].append({"node": parts[2], "ip": parts[0], "dc": parts[1], "patroni_role": "NOT_INSTALLED" if not installed else "IDLE"})

            pubkey = get_orchestrator_pubkey()
            senv = read_secrets_dict()
            bk_ak = senv.get("BACKUP_S3_ACCESS_KEY", "")
            bk_sk = senv.get("BACKUP_S3_SECRET_KEY", "")
            backup_configured = bool(bk_ak and "FIXME" not in bk_ak and bk_sk and "FIXME" not in bk_sk)
            self.send_json(
                200,
                {
                    "installed": installed,
                    "orchestrator_pubkey": pubkey,
                    "backup_configured": backup_configured,
                    "config": {
                        "PROJECT_NAME": cenv.get("PROJECT_NAME", "Ligament Vault"),
                        "CLUSTER_SLUG": cenv.get("CLUSTER_SLUG", "ligament-vault"),
                        "CLUSTER_NODES": nodes_raw,
                        "DOMAIN": cenv.get("DOMAIN", ""),
                        "HTTPS_PORT": cenv.get("HTTPS_PORT", "443"),
                        "SFTP_PORT": cenv.get("SFTP_PORT", "2022"),
                        "FTPS_PORT": cenv.get("FTPS_PORT", "21"),
                        "ADMIN_SSH_NET": cenv.get("ADMIN_SSH_NET", "0.0.0.0/0"),
                        "WORM_RETENTION_MODE": cenv.get("WORM_RETENTION_MODE", "COMPLIANCE"),
                        "WORM_RETENTION_DAYS": cenv.get("WORM_RETENTION_DAYS", "365"),
                        "LIGAMENT_2FA_ENABLED": cenv.get("LIGAMENT_2FA_ENABLED", "false"),
                        "LIGAMENT_2FA_API_URL": cenv.get("LIGAMENT_2FA_API_URL", ""),
                        "LIGAMENT_2FA_FAIL_OPEN": cenv.get("LIGAMENT_2FA_FAIL_OPEN", "false"),
                        "FAILOVER_MODE": cenv.get("FAILOVER_MODE", "dns"),
                        "ARBITER_IP": cenv.get("ARBITER_IP", ""),
                        "BACKUP_S3_ENDPOINT": "" if "backup-provider.com" in senv.get("BACKUP_S3_ENDPOINT", "") else senv.get("BACKUP_S3_ENDPOINT", ""),
                        "BACKUP_S3_REGION": senv.get("BACKUP_S3_REGION", "us-east-1"),
                        "BACKUP_S3_BUCKET": senv.get("BACKUP_S3_BUCKET", ""),
                    },
                    "health": health,
                },
            )
            return

        if path == "/api/v1/users":
            installed = os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed"))
            if not installed:
                self.send_json(200, {"users": [], "installed": False})
                return
            res = subprocess.run(
                [os.path.join(REPO_DIR, "ligactl"), "user", "list", "--json"],
                cwd=REPO_DIR,
                env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT},
                capture_output=True,
                text=True,
                timeout=20,
            )
            if res.returncode != 0:
                self.send_json(500, {"error": res.stderr.strip() or "Не удалось получить список пользователей"})
                return
            try:
                users = json.loads(res.stdout)
            except Exception:
                users = []
            f_res = subprocess.run(
                [os.path.join(REPO_DIR, "ligactl"), "user", "list-folders"],
                cwd=REPO_DIR,
                env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT},
                capture_output=True,
                text=True,
                timeout=15,
            )
            try:
                folders = json.loads(f_res.stdout) if f_res.returncode == 0 else []
            except Exception:
                folders = []
            self.send_json(200, {"users": users, "folders": folders, "installed": True})
            return

        if path == "/api/v1/tasks":
            with LOCK:
                items = sorted(TASKS.values(), key=lambda x: x["started"], reverse=True)[:10]
                summary = [{k: v for k, v in t.items() if k != "log"} | {"lines": len(t["log"])} for t in items]
            self.send_json(200, {"tasks": summary})
            return

        if path.startswith("/api/v1/tasks/"):
            tid = path.rsplit("/", 1)[-1]
            qs = parse_qs(parsed.query)
            offset = int(qs.get("offset", ["0"])[0])
            with LOCK:
                t = TASKS.get(tid)
                if not t:
                    self.send_json(404, {"error": "Задача не найдена"})
                    return
                chunk = t["log"][offset:]
                payload = {
                    "id": t["id"],
                    "label": t["label"],
                    "status": t["status"],
                    "rc": t["rc"],
                    "elapsed_sec": int(time.time() - t["started"]),
                    "next_offset": offset + len(chunk),
                    "lines": chunk,
                }
            self.send_json(200, payload)
            return

        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        client_ip = self.client_address[0]

        if path == "/api/v1/auth/login":
            now = time.time()
            with LOCK:
                attempts = [t for t in RATE_LIMIT.get(client_ip, []) if now - t < FAIL_WINDOW_SEC]
                RATE_LIMIT[client_ip] = attempts
                if len(attempts) >= MAX_FAILED_LOGINS:
                    self.send_json(429, {"error": "Слишком много попыток входа. Подождите 5 минут."})
                    return

            body = self.read_body_json()
            exp_user, exp_pw = get_admin_credentials()
            in_user = str(body.get("username", ""))
            in_pw = str(body.get("password", ""))
            if exp_pw and hmac.compare_digest(in_user, exp_user) and hmac.compare_digest(in_pw, exp_pw):
                sid = secrets.token_urlsafe(32)
                csrf = secrets.token_hex(16)
                with LOCK:
                    SESSIONS[sid] = {"csrf": csrf, "exp": now + SESSION_TTL}
                    RATE_LIMIT.pop(client_ip, None)
                cookie = f"lv_session={sid}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age={SESSION_TTL}"
                self.send_json(200, {"ok": True, "csrf": csrf}, extra_headers={"Set-Cookie": cookie})
            else:
                with LOCK:
                    RATE_LIMIT.setdefault(client_ip, []).append(now)
                self.send_json(401, {"error": "Неверный логин или пароль"})
            return

        if path == "/api/v1/auth/logout":
            jar = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
            if "lv_session" in jar:
                with LOCK:
                    SESSIONS.pop(jar["lv_session"].value, None)
            self.send_json(200, {"ok": True}, extra_headers={"Set-Cookie": "lv_session=; HttpOnly; Secure; Path=/; Max-Age=0"})
            return

        if not self.check_session(require_csrf=True):
            self.send_json(403, {"error": "Сессия истекла или некорректный CSRF-токен"})
            return

        body = self.read_body_json()

        if path == "/api/v1/nodes/connect":
            ip = str(body.get("ip", "")).strip()
            ssh_port = int(body.get("ssh_port") or 22)
            root_pw = str(body.get("password", ""))
            dc_input = str(body.get("dc", "")).strip()
            auto_join = bool(body.get("auto_join", False))

            if not re.match(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$", ip):
                self.send_json(400, {"error": "Укажите корректный IPv4 адрес VPS"})
                return
            pubkey = get_orchestrator_pubkey()
            if not pubkey:
                self.send_json(500, {"error": "На главном сервере не найден SSH-ключ (/root/.ssh/id_ed25519.pub)"})
                return

            if os.environ.get("DRY_RUN") == "true":
                ok, msg = True, "[DRY-RUN] VPS подключен"
            else:
                ok, msg = bootstrap_remote_vps_ssh(ip, ssh_port, root_pw, pubkey)
            if not ok:
                self.send_json(400, {"error": msg})
                return

            cenv_path = os.path.join(CONFIG_ROOT, "cluster.env")
            cenv = read_env_dict(cenv_path)
            existing = [e for e in cenv.get("CLUSTER_NODES", "").split() if "FIXME" not in e]
            installed = os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed"))

            # Если кластер уже установлен и включен auto_join — запускаем живой scale add!
            if installed and auto_join:
                next_idx = len(existing) + 1
                dc = dc_input or f"dc{next_idx}"
                role = str(body.get("role", "edge")).strip() or "edge"
                ligactl = os.path.join(REPO_DIR, "ligactl")
                tid, err = start_async_task(
                    f"Ввод нового VPS {ip} ({dc}) в работающий кластер",
                    [ligactl, "scale", "add", "--ip", ip, "--dc", dc, "--role", role, "--yes"],
                )
                if err:
                    self.send_json(409, {"error": err})
                    return
                self.send_json(200, {"ok": True, "message": msg, "task_id": tid, "joined_live": True})
                return

            # Иначе добавляем узел в список CLUSTER_NODES для первичного объединения в кластер
            already_ips = {e.split(":")[0] for e in existing}
            if ip not in already_ips:
                next_idx = len(existing) + 1
                dc = dc_input or f"dc{next_idx}"
                name = f"node{next_idx}"
                existing.append(f"{ip}:{dc}:{name}")
                update_env_file(cenv_path, {"CLUSTER_NODES": " ".join(existing), "ADMIN_SSH_PORT": str(ssh_port)})

            self.send_json(200, {"ok": True, "message": msg, "cluster_nodes": " ".join(existing), "joined_live": False})
            return

        if path == "/api/v1/nodes/remove":
            target_node = str(body.get("node", "")).strip()
            if not re.match(r"^[a-zA-Z0-9_-]+$", target_node):
                self.send_json(400, {"error": "Некорректное имя узла"})
                return
            installed = os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed"))
            cenv_path = os.path.join(CONFIG_ROOT, "cluster.env")
            cenv = read_env_dict(cenv_path)
            existing = [e for e in cenv.get("CLUSTER_NODES", "").split() if "FIXME" not in e]

            if not installed:
                kept = [e for e in existing if e.split(":")[-1] != target_node]
                # Перенумеровываем dcN:nodeN по порядку, чтобы не было дыр до установки
                reindexed = [f"{e.split(':')[0]}:dc{i+1}:node{i+1}" for i, e in enumerate(kept)]
                update_env_file(cenv_path, {"CLUSTER_NODES": " ".join(reindexed)})
                ck = os.path.join(CONFIG_ROOT, ".state", "checkpoints.install")
                if os.path.exists(ck):
                    os.remove(ck)
                self.send_json(200, {"ok": True, "removed_preinstall": True, "cluster_nodes": " ".join(reindexed)})
                return

            if len(existing) <= 3:
                self.send_json(400, {"error": "В работающем кластере из 3 нод нельзя просто удалить узел (потеряется кворум) — используйте кнопку «Заменить» на новый IP!"})
                return
            ligactl = os.path.join(REPO_DIR, "ligactl")
            tid, err = start_async_task(f"Безопасный вывод узла {target_node} из кластера", [ligactl, "scale", "remove", "--node", target_node, "--yes"])
            if err:
                self.send_json(409, {"error": err})
                return
            self.send_json(200, {"ok": True, "removed_preinstall": False, "task_id": tid})
            return

        if path == "/api/v1/nodes/replace":
            target_node = str(body.get("node", "")).strip()
            new_ip = str(body.get("new_ip", "")).strip()
            ssh_port = int(body.get("ssh_port") or 22)
            root_pw = str(body.get("password", ""))
            if not re.match(r"^[a-zA-Z0-9_-]+$", target_node) or not re.match(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$", new_ip):
                self.send_json(400, {"error": "Укажите корректное имя узла и новый IPv4 адрес"})
                return
            pubkey = get_orchestrator_pubkey()
            if os.environ.get("DRY_RUN") != "true":
                ok, msg = bootstrap_remote_vps_ssh(new_ip, ssh_port, root_pw, pubkey)
                if not ok:
                    self.send_json(400, {"error": msg})
                    return
            installed = os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed"))
            cenv_path = os.path.join(CONFIG_ROOT, "cluster.env")
            cenv = read_env_dict(cenv_path)
            existing = [e for e in cenv.get("CLUSTER_NODES", "").split() if "FIXME" not in e]
            if not installed:
                updated = []
                for e in existing:
                    parts = e.split(":")
                    if len(parts) >= 3 and parts[2] == target_node:
                        updated.append(f"{new_ip}:{parts[1]}:{parts[2]}")
                    else:
                        updated.append(e)
                update_env_file(cenv_path, {"CLUSTER_NODES": " ".join(updated)})
                self.send_json(200, {"ok": True, "replaced_preinstall": True, "cluster_nodes": " ".join(updated)})
                return
            ligactl = os.path.join(REPO_DIR, "ligactl")
            tid, err = start_async_task(f"Замена узла {target_node} -> {new_ip}", [ligactl, "scale", "replace", "--old", target_node, "--new-ip", new_ip, "--yes"])
            if err:
                self.send_json(409, {"error": err})
                return
            self.send_json(200, {"ok": True, "replaced_preinstall": False, "task_id": tid})
            return

        if path == "/api/v1/config":
            allowed_cluster = (
                "CLUSTER_NODES", "DOMAIN", "HTTPS_PORT", "ADMIN_SSH_NET", "SFTP_PORT", "FTPS_PORT",
                "WORM_RETENTION_MODE", "WORM_RETENTION_DAYS", "LIGAMENT_2FA_ENABLED",
                "LIGAMENT_2FA_API_URL", "LIGAMENT_2FA_FAIL_OPEN", "FAILOVER_MODE", "ARBITER_IP",
            )
            c_updates = {k: body[k] for k in allowed_cluster if k in body}
            if c_updates:
                update_env_file(os.path.join(CONFIG_ROOT, "cluster.env"), c_updates)

            allowed_secrets = (
                "CF_DNS_API_TOKEN", "LIGAMENT_2FA_API_TOKEN",
                "BACKUP_S3_ENDPOINT", "BACKUP_S3_REGION", "BACKUP_S3_BUCKET",
                "BACKUP_S3_ACCESS_KEY", "BACKUP_S3_SECRET_KEY", "BACKUP_ENCRYPTION_KEY",
            )
            s_updates = {k: body[k] for k in allowed_secrets if k in body and body[k]}
            if s_updates:
                try:
                    update_secrets(s_updates)
                except Exception as exc:
                    self.send_json(500, {"error": str(exc)})
                    return
            self.send_json(200, {"ok": True})
            return

        if path == "/api/v1/storage/s3-folder":
            if not os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed")):
                self.send_json(400, {"error": "Сначала завершите установку кластера во вкладке «Установка и Масштаб»"})
                return
            fname = str(body.get("name", "")).strip()
            endpoint = str(body.get("endpoint", "")).strip()
            bucket = str(body.get("bucket", "")).strip()
            region = str(body.get("region", "us-east-1")).strip() or "us-east-1"
            ak = str(body.get("access_key", "")).strip()
            sk = str(body.get("secret_key", "")).strip()
            if not re.match(r"^[a-zA-Z0-9_-]+$", fname) or not endpoint or not bucket or not ak or not sk:
                self.send_json(400, {"error": "Заполните имя папки (латиница), Endpoint, Bucket, Access Key и Secret Key"})
                return
            cmd = [
                os.path.join(REPO_DIR, "ligactl"), "user", "add-s3-folder",
                "--name", fname, "--endpoint", endpoint, "--bucket", bucket,
                "--region", region, "--access-key", ak, "--secret-key", sk,
            ]
            res = subprocess.run(cmd, cwd=REPO_DIR, env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT}, capture_output=True, text=True, timeout=25)
            if res.returncode != 0:
                self.send_json(400, {"error": (res.stderr.strip() or res.stdout.strip() or "Ошибка подключения S3").splitlines()[-1]})
                return
            self.send_json(200, {"ok": True, "name": fname})
            return

        if path == "/api/v1/users":
            if not os.path.exists(os.path.join(CONFIG_ROOT, ".cluster_installed")):
                self.send_json(400, {"error": "Кластер еще устанавливается (или не развернут). Откройте вкладку «Консоль задач», дождитесь завершения Стадии 5 и повторите."})
                return
            uname = str(body.get("username", "")).strip()
            profile = str(body.get("profile", "dual")).strip()
            quota_gb = str(body.get("quota_gb", "0")).strip() or "0"
            ssh_key = str(body.get("ssh_key", "")).strip()
            pw = str(body.get("password", "")).strip()
            req_2fa = bool(body.get("require_2fa", False))

            cmd = [os.path.join(REPO_DIR, "ligactl"), "user", "add", "--username", uname, "--profile", profile, "--quota-gb", quota_gb]
            generated_pw = False
            if pw:
                cmd += ["--password", pw]
            elif not ssh_key:
                cmd += ["--generate-password"]
                generated_pw = True
            if ssh_key:
                cmd += ["--ssh-key", ssh_key]
            if req_2fa:
                cmd += ["--require-2fa"]

            res = subprocess.run(cmd, cwd=REPO_DIR, env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT}, capture_output=True, text=True, timeout=30)
            if res.returncode != 0:
                raw_err = (res.stderr.strip() or res.stdout.strip())
                if "ConnectionRefusedError" in raw_err or "Errno 111" in raw_err or "недоступен на 127.0.0.1:8081" in raw_err:
                    raw_err = "Сервис SFTPGo (127.0.0.1:8081) еще не запущен на активном узле — проверьте статус кластера во вкладке «Консоль задач»."
                else:
                    err_lines = [ln.strip() for ln in raw_err.splitlines() if ln.strip() and not ln.strip().startswith(("File ", "Traceback "))]
                    raw_err = err_lines[-1] if err_lines else "Ошибка создания клиента"
                self.send_json(400, {"error": raw_err})
                return
            out_pw = pw
            if generated_pw:
                m = re.search(r"Сгенерированный пароль для '[^']+':\s*(\S+)", res.stdout)
                if m:
                    out_pw = m.group(1)
            self.send_json(200, {"ok": True, "username": uname, "password": out_pw, "output": res.stdout})
            return

        if path == "/api/v1/users/action":
            act = str(body.get("action", ""))
            uname = str(body.get("username", ""))
            if act not in ("disable", "enable", "disconnect", "set-quota") or not uname:
                self.send_json(400, {"error": "Некорректное действие"})
                return
            cmd = [os.path.join(REPO_DIR, "ligactl"), "user", act, "--username", uname]
            if act == "set-quota":
                cmd += ["--quota-gb", str(body.get("quota_gb", "0"))]
            res = subprocess.run(cmd, cwd=REPO_DIR, env={**os.environ, "CONFIG_ROOT": CONFIG_ROOT}, capture_output=True, text=True, timeout=25)
            if res.returncode != 0:
                self.send_json(400, {"error": res.stderr.strip() or res.stdout.strip()})
                return
            self.send_json(200, {"ok": True})
            return

        if path == "/api/v1/tasks/start":
            action = str(body.get("action", ""))
            ligactl = os.path.join(REPO_DIR, "ligactl")
            mapping = {
                "preflight": ("Проверка готовности VPS (Preflight)", [ligactl, "preflight"]),
                "install": ("Полная установка кластера (Стадии 0–5)", [ligactl, "install", "--yes"]),
                "install-resume": ("Продолжение установки (--resume)", [ligactl, "install", "--yes", "--resume"]),
                "sync-config": ("Применение конфигурации и UFW (sync-config)", [ligactl, "sync-config"]),
                "verify-sprint1": ("Приемочный тест S3 + WORM (Sprint 1)", [ligactl, "verify", "--sprint", "1"]),
                "pki-status": ("Проверка сроков mTLS сертификатов", [ligactl, "pki", "status"]),
                "pki-rotate": ("Бесшовная ротация mTLS сертификатов", [ligactl, "pki", "rotate", "--all", "--yes"]),
                "backup-incr": ("Инкрементальный бэкап БД + SeaweedFS", ["bash", os.path.join(REPO_DIR, "scripts/ops/backup-job.sh"), "incr"]),
                "backup-full": ("Полный бэкап БД + SeaweedFS", ["bash", os.path.join(REPO_DIR, "scripts/ops/backup-job.sh"), "full"]),
                "backup-verify": ("Проверка восстановления из внешнего S3 (verify-restore)", ["bash", os.path.join(REPO_DIR, "scripts/ops/backup-job.sh"), "verify-restore"]),
                "upgrade": ("Rolling-обновление кластера", [ligactl, "upgrade", "--yes"]),
                "self-update": ("Обновление Ligament Vault с GitHub", ["bash", "-c", f"git -C '{REPO_DIR}' fetch --quiet origin main && git -C '{REPO_DIR}' reset --hard origin/main >/dev/null && chmod +x '{REPO_DIR}'/ligactl '{REPO_DIR}'/clusterctl '{REPO_DIR}'/web/panel.py '{REPO_DIR}'/scripts/lib/*.sh '{REPO_DIR}'/scripts/stages/*.sh '{REPO_DIR}'/scripts/ops/*.sh '{REPO_DIR}'/scripts/verify/*.sh '{REPO_DIR}'/scripts/hooks/*.sh && echo '✅ Код обновлен! Перезапускаем веб-панель...' && (nohup bash -c 'sleep 1 && systemctl restart ligament-vault-ui' >/dev/null 2>&1 &)"]),
            }
            if action == "scale-add":
                ip = str(body.get("ip", "")).strip()
                dc = str(body.get("dc", "")).strip()
                role = str(body.get("role", "edge")).strip()
                if not re.match(r"^[0-9.]+$", ip) or not re.match(r"^[a-zA-Z0-9_-]+$", dc) or role not in ("edge", "quorum"):
                    self.send_json(400, {"error": "Укажите корректные IP, DC и роль (edge/quorum)"})
                    return
                label, argv = (f"Добавление ноды {ip} ({dc}, {role})", [ligactl, "scale", "add", "--ip", ip, "--dc", dc, "--role", role, "--yes"])
            elif action in mapping:
                label, argv = mapping[action]
            else:
                self.send_json(400, {"error": f"Неизвестная операция: {action}"})
                return

            tid, err = start_async_task(label, argv)
            if err:
                self.send_json(409, {"error": err})
                return
            self.send_json(200, {"ok": True, "task_id": tid})
            return

        self.send_json(404, {"error": "Not found"})


def main():
    cenv = read_env_dict(os.path.join(CONFIG_ROOT, "cluster.env"))
    port = int(os.environ.get("PANEL_PORT") or cenv.get("PANEL_PORT") or 9443)
    bind_addr = os.environ.get("PANEL_BIND", "0.0.0.0")
    crt, key = ensure_tls_cert()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(certfile=crt, keyfile=key)

    ThreadingHTTPServer.allow_reuse_address = True
    srv = ThreadingHTTPServer((bind_addr, port), PanelHandler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"[Ligament Vault UI] HTTPS панель запущена на https://{bind_addr}:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
