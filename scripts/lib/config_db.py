"""Control database for a cluster. Only the age identity is stored outside SQLite."""
import argparse
from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
from node_address import valid_node_address
import re
import secrets
import shlex
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DEFAULTS = json.loads((ROOT / "configs/control-defaults.json").read_text())
PROVIDER_PREFIXES = ("CF_", "CLOUDFLARE_", "AWS_", "HETZNER_", "DO_", "DIGITALOCEAN_",
                     "ROUTE53_", "OVH_", "GANDI_", "LINODE_", "PORKBUN_", "NAMECHEAP_", "DESEC_")
EXTRA = {"REMOTE_BASE_DIR", "ARBITER_BASE_DIR", "SWFS_VOLUME_MAX_PER_DIR",
         "SWFS_VOLUME_MAX_OVERRIDE", "NODE_EXPORTER_BIND", "PANEL_ADMIN_USER"}


def group(key):
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
        raise ValueError("Некорректное имя параметра")
    for part, values in DEFAULTS.items():
        if key in values:
            return part
    if key.startswith(PROVIDER_PREFIXES):
        return "secrets"
    if key in EXTRA:
        return "settings"
    raise ValueError(f"Неизвестный параметр {key}")


def generate(value):
    if value in ("FIXME_GENERATE", "FIXME_GENERATE_PASSPHRASE", "FIXME_CA_PASSPHRASE"):
        return secrets.token_hex(24)
    if value == "FIXME_GENERATE_32_BYTE_HEX":
        return secrets.token_hex(32)
    if value == "FIXME_UNIQUE_CODE":
        return secrets.token_hex(16)
    return value


def legacy_values(text):
    result = {}
    for i, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, raw = line.partition("=")
        if not sep:
            raise ValueError(f"Некорректная строка старой конфигурации {i}")
        group(key)
        # Use a lexer, never execute the old shell file. Preserve escaped dollar signs.
        items = shlex.split(raw, comments=True, posix=True)
        if len(items) > 1:
            raise ValueError(f"Неоднозначное значение {key} в строке {i}")
        val = items[0] if items else ""
        if raw.lstrip().startswith('"'):
            val = val.replace(r"\$", "$").replace(r"\`", "`")
        result[key] = val
    return result


def age(*args, data=None):
    result = subprocess.run(list(args), input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").splitlines()
        raise ValueError(detail[0] if detail else f"{args[0]} завершился с кодом {result.returncode}")
    return result.stdout


class Store:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.path = self.root / "control.sqlite3"
        self.identity = self.root / ".control.agekey"

    @contextmanager
    def connect(self, init=False, write=False):
        if init:
            self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            os.close(fd)
        with closing(sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True,
                                     timeout=30, isolation_level=None)) as db:
            db.execute("BEGIN IMMEDIATE" if write or init else "BEGIN")
            try:
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def secrets(self, db):
        row = db.execute("SELECT ciphertext FROM secret_store WHERE id=1").fetchone()
        if not row:
            return {}
        return json.loads(age("age", "-d", "-i", str(self.identity), data=row[0]))

    def save_secrets(self, db, values):
        if not self.identity.exists():
            if db.execute("SELECT 1 FROM secret_store").fetchone():
                raise ValueError("Утерян ключ расшифровки базы")
            age("age-keygen", "-o", str(self.identity))
        recipient = age("age-keygen", "-y", str(self.identity)).decode().strip()
        ciphertext = age("age", "-r", recipient, data=json.dumps(values).encode())
        db.execute("INSERT OR REPLACE INTO secret_store VALUES(1,?)", (ciphertext,))

    def init(self, migrate=True, legacy_identity=None, arbiter=False):
        with self.connect(init=True) as db:
            db.execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS secret_store(id INTEGER PRIMARY KEY CHECK(id=1),ciphertext BLOB NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS image_snapshot(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            existing = db.execute("SELECT 1 FROM secret_store").fetchone()
            old = {}
            if not existing and migrate and (self.identity.exists() or (self.root / ".cluster_installed").exists()):
                if not any((self.root / f).is_file() for f in ("secrets.env", "secrets.env.age")):
                    raise ValueError("Обнаружены ключ или метка работающего кластера. Восстановите control.sqlite3 из резервной копии.")
            if not existing and migrate:
                for f in ("versions.env", "cluster.env", "secrets.env"):
                    if (self.root / f).is_file():
                        old.update(legacy_values((self.root / f).read_text()))
                encrypted = self.root / "secrets.env.age"
                if encrypted.exists() and not (self.root / "secrets.env").exists():
                    key = legacy_identity or Path.home() / ".config/ligament/age.key"
                    old.update(legacy_values(age("age", "-d", "-i", str(key), str(encrypted)).decode()))
                if legacy_identity is not None:
                    old["LEGACY_CA_IDENTITY"] = str(Path(legacy_identity).resolve())
                voters = self.root / ".quorum_nodes"
                if voters.exists():
                    old["QUORUM_NODES"] = " ".join(voters.read_text().split())
            for k, v in {**DEFAULTS["images"], **DEFAULTS["settings"], **old}.items():
                if group(k) != "secrets":
                    db.execute("INSERT OR IGNORE INTO settings VALUES(?,?)", (k, v))
            sec = self.secrets(db)
            merged = {**({} if arbiter else {k: generate(v) for k,v in DEFAULTS["secrets"].items()}),
                      **{k:v for k,v in old.items() if group(k) == "secrets"}, **sec}
            if sec != merged or not existing:
                self.save_secrets(db, merged)

    def read(self, include_secrets=False):
        with self.connect() as db:
            result = dict(db.execute("SELECT key,value FROM settings"))
            if include_secrets:
                result.update(self.secrets(db))
            return result

    def update(self, values, expected=None):
        clean = {}
        for key, value in values.items():
            group(key)
            if not isinstance(value, str) or any(c in value for c in ("\0","\r","\n")):
                raise ValueError(f"Недопустимое значение {key}")
            if key == "CLUSTER_NODES":
                inventory = [entry.split(":") for entry in value.split()]
                if (not inventory and (self.root / ".cluster_installed").exists()) or any(len(n) != 3 or not valid_node_address(n[0])
                        or not all(re.fullmatch(r"[A-Za-z0-9_-]{1,32}", part) for part in n[1:]) for n in inventory):
                    raise ValueError("Ожидается список узлов в формате FQDN:ЦОД:имя или IPv4:ЦОД:имя")
                if any(len({n[i].lower() for n in inventory}) != len(inventory) for i in (0, 2)):
                    raise ValueError("Адреса и имена узлов должны быть уникальными")
            elif key == "DOMAIN" and (not valid_node_address(value) or value.replace(".", "").isdigit()):
                raise ValueError("DOMAIN должен содержать DNS-имя сервиса")
            elif key == "ARBITER_IP" and value and not valid_node_address(value):
                raise ValueError("Некорректный адрес арбитра")
            elif key.endswith("_PORT") and (not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 65535):
                raise ValueError(f"Некорректный порт {key}")
            clean[key] = value
        if "PG_SYNC_STANDBY_COUNT" in clean:
            if not re.fullmatch(r"0|[1-9][0-9]?", clean["PG_SYNC_STANDBY_COUNT"]):
                raise ValueError("PG_SYNC_STANDBY_COUNT должен быть целым числом от 0 до 99")
            clean["PG_SYNC_MANAGED"] = "true"
        with self.connect(write=True) as db:
            if expected is not None:
                for k, v in expected.items():
                    row = db.execute("SELECT value FROM settings WHERE key=?", (k,)).fetchone()
                    if not row or row[0] != v:
                        raise ValueError("Конфигурация изменилась, повторите операцию")
            secret_values = {k:v for k,v in clean.items() if group(k) == "secrets"}
            if secret_values:
                self.save_secrets(db, {**self.secrets(db), **secret_values})
            db.executemany("INSERT OR REPLACE INTO settings VALUES(?,?)",
                           ((k,v) for k,v in clean.items() if group(k) != "secrets"))

    def ha_five(self):
        cfg = self.read()
        nodes = [n.split(":") for n in cfg["CLUSTER_NODES"].split()]
        if len(nodes) < 5 or any(len(n) != 3 or "FIXME" in n[0] for n in nodes):
            raise ValueError("Нужны пять узлов в инвентаре")
        if any(len({n[i] for n in nodes[:5]}) != 5 for i in range(3)):
            raise ValueError("Первые пять узлов должны иметь разные адреса, ЦОД и имена")
        if (self.root / ".cluster_installed").exists() or (self.root / ".state/checkpoints.install").exists():
            raise ValueError("Этот профиль задаётся до установки; у работающего кластера меняйте membership и копии с проверкой")
        self.update({"QUORUM_NODES": " ".join(n[2] for n in nodes[:5]),
                     "SWFS_DEFAULT_REPLICATION":"200","SWFS_VOLUME_GROWTH_COUNT":"3",
                     "PG_SYNC_STANDBY_COUNT":"2"}, {"CLUSTER_NODES":cfg["CLUSTER_NODES"]})


def nul_values():
    parts = sys.stdin.buffer.read().split(b"\0")
    if not parts or parts.pop() != b"" or len(parts) % 2:
        raise ValueError("Неполный список параметров")
    return {parts[i].decode():parts[i+1].decode() for i in range(0,len(parts),2)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--legacy-identity", type=Path, help="ключ age прежнего контроллера для однократного импорта")
    parser.add_argument("action", choices=("init","get","set","batch","pairs","ha-five",
                                          "arbiter-export","arbiter-import","lego-files","images-save","images-restore"))
    parser.add_argument("keys", nargs="*")
    args = parser.parse_args()
    s = Store(args.root)
    if args.action == "init":
        s.init(legacy_identity=args.legacy_identity)
    elif args.action == "ha-five":
        s.ha_five()
    elif args.action in ("get","set"):
        if len(args.keys)!=1:
            parser.error("нужен один ключ")
        key=args.keys[0]
        if args.action=="get":
            print(s.read(group(key)=="secrets")[key])
        else:
            s.update({key:sys.stdin.read().removesuffix("\n")})
    elif args.action=="batch":
        s.update(nul_values())
    elif args.action=="pairs":
        for k,v in s.read(True).items():
            group(k)
            sys.stdout.buffer.write(k.encode()+b"\0"+v.encode()+b"\0")
        sys.stdout.buffer.write(b"_END\x00ok\x00")
    elif args.action == "lego-files":
        dest = Path(args.keys[0])
        values = s.read(True)
        prefixes = {"cloudflare":("CF_", "CLOUDFLARE_"), "route53":("AWS_",),
                    "hetzner":("HETZNER_",), "digitalocean":("DO_", "DIGITALOCEAN_"),
                    "gandiv5":("GANDI_",)}
        provider = values["DNS_PROVIDER"]
        selected = prefixes.get(provider, (provider.upper() + "_",))
        for k, v in values.items():
            if group(k) == "secrets" and k.startswith(selected) and v and "FIXME" not in v:
                fd = os.open(dest / k, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w") as out:
                    out.write(v)
    elif args.action.startswith("images-"):
        with s.connect(write=True) as db:
            if args.action=="images-save":
                db.execute("DELETE FROM image_snapshot")
                db.executemany("INSERT INTO image_snapshot SELECT key,value FROM settings WHERE key=?",
                               ((k,) for k in DEFAULTS["images"]))
            else:
                if not db.execute("SELECT 1 FROM image_snapshot").fetchone():
                    raise ValueError("В базе нет снимка версий")
                db.execute("INSERT OR REPLACE INTO settings SELECT * FROM image_snapshot")
    else:
        # The arbiter has its own identity and never receives the controller's private key.
        allowed = {"CLUSTER_NODES", "CLUSTER_SLUG", "QUORUM_NODES", "DOMAIN", "HTTPS_PORT", "FTPS_PORT",
                   "SFTP_PORT", "PATRONI_API_PORT", "ADMIN_SSH_PORT", "DNS_PROVIDER", "DNS_TTL", "DNS_UPDATE_HOOK",
                   "CLOUDFLARE_ZONE_ID", "FLOATING_IP_PROVIDER", "FLOATING_IP_ID", "FLOATING_IP_HOOK",
                   "FAILOVER_MODE", "EDGE_PROBE_PASSWORD", "HETZNER_CLOUD_TOKEN", "DO_API_TOKEN", "CF_DNS_API_TOKEN"}
        if args.action=="arbiter-export":
            vals = s.read(True)
            print(json.dumps({k:v for k,v in vals.items() if k in allowed}))
        else:
            values=json.load(sys.stdin)
            if any(k not in allowed for k in values):
                raise ValueError("Параметр вне области арбитра")
            s.init(migrate=False, arbiter=True)
            s.update(values)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"control.sqlite3: {error}")
