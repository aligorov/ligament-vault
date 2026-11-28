#!/usr/bin/env python3
"""Encrypted physical SeaweedFS snapshots paired with PostgreSQL named restore points."""
import argparse
import base64
import configparser
import datetime as dt
import hashlib
from functools import lru_cache
import hmac
import json
import os
from pathlib import Path
import ipaddress
import re
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib

BLOCK = 8 * 1024 * 1024
UTC = dt.timezone.utc


class SnapshotChanged(Exception):
    """Retry an online snapshot when source volumes changed at the recovery boundary."""


def packed(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


class S3:
    def __init__(self, endpoint, region, access, secret):
        self.endpoint = endpoint.rstrip("/")
        self.region, self.access, self.secret = region, access, secret
        url = urllib.parse.urlsplit(self.endpoint)
        if url.scheme not in ("https", "http") or not url.hostname or url.path or url.query or url.username:
            raise ValueError("S3 endpoint requires a host without a path or credentials")
        if url.scheme == "http" and url.hostname not in ("127.0.0.1", "localhost"):
            raise ValueError("external S3 requires HTTPS")
        if url.scheme == "https":
            try:
                ipaddress.ip_address(url.hostname)
            except ValueError:
                pass
            else:
                raise ValueError("external S3 requires a DNS hostname")
        self.host = url.netloc

    def call(self, method, bucket, key="", query=None, body=b""):
        now = dt.datetime.now(UTC)
        stamp, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
        path = "/" + urllib.parse.quote(bucket, safe="") + ("/" + urllib.parse.quote(key, safe="/") if key else "")
        qs = urllib.parse.urlencode(sorted((query or {}).items()), quote_via=urllib.parse.quote)
        digest = hashlib.sha256(body).hexdigest()
        fields = {"host": self.host, "x-amz-content-sha256": digest, "x-amz-date": stamp}
        signed = ";".join(sorted(fields))
        canonical = "".join(k + ":" + fields[k] + "\n" for k in sorted(fields))
        scope = f"{day}/{self.region}/s3/aws4_request"
        request_hash = hashlib.sha256(f"{method}\n{path}\n{qs}\n{canonical}\n{signed}\n{digest}".encode()).hexdigest()
        signkey = ("AWS4" + self.secret).encode()
        for term in (day, self.region, "s3", "aws4_request"):
            signkey = hmac.digest(signkey, term.encode(), "sha256")
        signature = hmac.new(signkey, f"AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{request_hash}".encode(), "sha256").hexdigest()
        fields["Authorization"] = f"AWS4-HMAC-SHA256 Credential={self.access}/{scope}, SignedHeaders={signed}, Signature={signature}"
        req = urllib.request.Request(self.endpoint + path + ("?" + qs if qs else ""), headers=fields, method=method,
                                     data=body if method == "PUT" else None)
        return urllib.request.urlopen(req, timeout=90)


class Archive:
    def __init__(self, s3, bucket, password, slug):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", slug) or not password:
            raise ValueError("invalid archive identity")
        self.s3, self.bucket, self.prefix = s3, bucket, "vault-snapshots/" + slug + "/v1/"
        material = hashlib.sha512(b"vault-physical-snapshot-v1\0" + password.encode()).digest()
        self.passphrase = base64.b64encode(material[:32])
        self.mac = material[32:]

    def crypt(self, data, decrypt=False):
        rfd, wfd = os.pipe()
        try:
            with os.fdopen(wfd, "wb") as stream:
                stream.write(self.passphrase + b"\n")
            cmd = ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "60000", "-pass", f"fd:{rfd}"]
            if decrypt:
                cmd += ["-d"]
            return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, pass_fds=(rfd,), check=True).stdout
        finally:
            os.close(rfd)

    def put(self, key, data):
        cipher = self.crypt(zlib.compress(data, 1))
        envelope = b"LVS1" + hmac.digest(self.mac, key.encode() + b"\0" + cipher, "sha256") + cipher
        with self.s3.call("PUT", self.bucket, self.prefix + key, body=envelope):
            pass

    def get(self, key):
        with self.s3.call("GET", self.bucket, self.prefix + key) as response:
            data = response.read()
        cipher = data[36:]
        if data[:4] != b"LVS1" or not hmac.compare_digest(data[4:36], hmac.digest(self.mac, key.encode() + b"\0" + cipher, "sha256")):
            raise ValueError("archive authentication failed: " + key)
        return zlib.decompress(self.crypt(cipher, True))

    @lru_cache(maxsize=4)
    def load_block(self, block):
        data = self.get("blocks/" + block)
        if not hmac.compare_digest(hmac.new(self.mac, data, "sha256").hexdigest(), block):
            raise ValueError("volume block checksum mismatch")
        return data

    def store_block(self, block, seen):
        digest = hmac.new(self.mac, block, "sha256").hexdigest()
        if digest in seen:
            return digest
        key = "blocks/" + digest
        try:
            with self.s3.call("HEAD", self.bucket, self.prefix + key):
                pass
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            exc.close()
            self.put(key, block)
        seen.add(digest)
        return digest

    def releases(self):
        token = ""
        while True:
            query = {"list-type": "2", "prefix": self.prefix + "points/"}
            if token:
                query["continuation-token"] = token
            with self.s3.call("GET", self.bucket, query=query) as resp:
                page = ET.parse(resp)
            for item in page.findall(".//{*}Contents/{*}Key"):
                yield item.text[len(self.prefix):]
            if page.findtext(".//{*}IsTruncated") != "true":
                break
            token = page.findtext(".//{*}NextContinuationToken")
            if not token:
                raise ValueError("invalid truncated S3 listing")


def inventory(roots):
    result = {}
    for i, root in enumerate(roots):
        if not root.is_dir() or root.is_symlink():
            raise ValueError("missing or unsafe SeaweedFS volume directory: " + str(root))
        for directory, children, files in os.walk(root):
            if Path(directory) == root and 'lost+found' in children:
                children.remove('lost+found')
            for child in children:
                if (Path(directory) / child).is_symlink():
                    raise ValueError("symbolic link in volume directory")
            for filename in files:
                p = Path(directory) / filename
                st = p.lstat()
                if not stat.S_ISREG(st.st_mode):
                    raise ValueError("nonregular file in volume: " + str(p))
                key = f"{i}/" + str(p.relative_to(root))
                result[key] = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
    return result


def volume_path(roots, name):
    disk, rel = name.split("/", 1)
    if not disk.isdecimal() or not rel or any(s in ("", ".", "..") for s in rel.split("/")):
        raise ValueError("unsafe archived path")
    root = roots[int(disk)].resolve()
    path = root / rel
    if any(p.is_symlink() for p in [path, *path.parents] if p != root and root in p.parents):
        raise ValueError("symbolic link in restore destination")
    return path


def capture(archive, nodekey, roots):
    before = inventory(roots)
    files, seen = {}, set()
    for name in sorted(before):
        blocks = []
        with volume_path(roots, name).open("rb") as src:
            while True:
                block = src.read(BLOCK)
                if not block:
                    break
                blocks.append(archive.store_block(block, seen))
        st = volume_path(roots, name).stat()
        files[name] = {"size": before[name][2], "blocks": blocks, "uid": st.st_uid, "gid": st.st_gid, "mode": st.st_mode & 0o777}
    if inventory(roots) != before:
        raise SnapshotChanged("volume files changed during backup")
    archive.put(nodekey, packed({"volumes": files, "stat": before, "disks": len(roots)}))


def prepare_destination(archive, nodekey, roots, node):
    if len(roots) != node["disks"]:
        raise ValueError("volume mount count differs from captured topology")
    existing = inventory(roots)
    prefix = ".lv-dr-" + nodekey.split("/")[1] + "-"
    for name in existing:
        path = volume_path(roots, name)
        if path.name.startswith(prefix):
            path.unlink()
            continue
        record = node["volumes"].get(name)
        if record is None or path.stat().st_size != record["size"]:
            raise ValueError("clean volume directory required: " + name)
        with path.open("rb") as stream:
            for digest in record["blocks"]:
                if not hmac.compare_digest(hmac.new(archive.mac, stream.read(BLOCK), "sha256").hexdigest(), digest):
                    raise ValueError("destination contains data from another recovery point: " + name)
    return prefix


def materialize(archive, nodekey, roots, restore):
    node = json.loads(archive.get(nodekey))
    prefix = prepare_destination(archive, nodekey, roots, node) if restore else ""
    for name, record in node["volumes"].items():
        path = volume_path(roots, name) if restore else None
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
        tmp = None
        try:
            if path:
                tmp = tempfile.NamedTemporaryFile(dir=path.parent, prefix=prefix, delete=False)
            size = 0
            for block in record["blocks"]:
                data = archive.load_block(block)
                size += len(data)
                if tmp:
                    tmp.write(data)
            if size != record["size"]:
                raise ValueError("volume size mismatch")
            if tmp:
                if os.geteuid() == 0:
                    os.fchown(tmp.fileno(), record["uid"], record["gid"])
                os.fchmod(tmp.fileno(), record["mode"])
                tmp.flush()
                os.fsync(tmp.fileno())
                tmp.close()
                os.replace(tmp.name, path)
        finally:
            if tmp:
                tmp.close()
                Path(tmp.name).unlink(missing_ok=True)


def object_evidence(base, port):
    cfg = json.loads((base / "configs/seaweedfs/s3.json").read_text())
    auth = next(c for i in cfg['identities'] for c in i.get('credentials', []) if c['accessKey'] == 'provision-s3-admin')
    store = S3(f'http://127.0.0.1:{port}', "us-east-1", auth['accessKey'], auth['secretKey'])
    totals = {}
    for bucket in ("sftp-work", "sftp-worm"):
        records = []
        if bucket == "sftp-worm":
            with store.call("GET", bucket, query={"object-lock": ""}) as response:
                lock = ET.parse(response)
            if lock.findtext(".//{*}ObjectLockEnabled") != "Enabled" or lock.findtext(".//{*}Mode") != "COMPLIANCE":
                raise ValueError("sftp-worm requires default COMPLIANCE object lock")
            records.append(hashlib.sha256(packed(sorted((el.tag.split('}')[-1], el.text.strip()) for el in lock.iter() if el.text and el.text.strip()))).hexdigest())
        query = {"versions": ""}
        while True:
            with store.call("GET", bucket, query=query) as response:
                page = ET.parse(response)
            for obj in page.getroot():
                kind = obj.tag.split('}')[-1]
                if kind not in ('Version', 'DeleteMarker'):
                    continue
                key = obj.findtext('{*}Key')
                ver = obj.findtext('{*}VersionId')
                if key is None or not ver:
                    raise ValueError("incomplete S3 version inventory")
                row = [kind, key, ver, obj.findtext('{*}IsLatest')]
                if kind == 'Version':
                    with store.call("GET", bucket, key, {"versionId": ver}) as resp:
                        h = hashlib.sha256()
                        while True:
                            block = resp.read(BLOCK)
                            if not block:
                                break
                            h.update(block)
                    row.append(h.hexdigest())
                    if bucket == 'sftp-worm':
                        with store.call("GET", bucket, key, {"versionId": ver, "retention": ""}) as resp:
                            retention = ET.parse(resp)
                        until = retention.findtext(".//{*}RetainUntilDate")
                        if retention.findtext(".//{*}Mode") != "COMPLIANCE" or not until:
                            raise ValueError("missing COMPLIANCE retention for a WORM version")
                        row += ["COMPLIANCE", until]
                records.append(hashlib.sha256(packed(row)).hexdigest())
            if page.findtext("{*}IsTruncated") != "true":
                break
            marker = page.findtext("{*}NextKeyMarker")
            if not marker:
                raise ValueError("invalid truncated version list")
            query["key-marker"] = marker
            next_version = page.findtext("{*}NextVersionIdMarker")
            if next_version:
                query["version-id-marker"] = next_version
            else:
                query.pop("version-id-marker", None)
        totals[bucket] = hashlib.sha256(packed(sorted(records))).hexdigest()
    return totals


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError("recovery timestamp requires an explicit UTC offset")
    return parsed.astimezone(UTC).isoformat(timespec='microseconds')


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("action", choices=["capture", "stable", "objects", "commit", "list", "select", "verify", "restore", "destination", "check-objects"])
    cli.add_argument("--base", type=Path)
    cli.add_argument("--database-settings", action="store_true")
    cli.add_argument("--slug", required=True)
    cli.add_argument("--id", default="")
    cli.add_argument("--node", type=int, default=1)
    cli.add_argument("--nodes", type=int, default=0)
    cli.add_argument("--dirs", default="")
    cli.add_argument("--port", type=int, default=8333)
    cli.add_argument("--at")
    cli.add_argument("--label")
    args = cli.parse_args()
    if args.action not in ('select', 'list') and not re.fullmatch(r"[0-9a-f]{32}", args.id):
        raise ValueError("invalid recovery set ID")
    if args.database_settings:
        with os.fdopen(3, "rb") as source:
            endpoint, region, bucket, access, secret, password = source.read().decode().split("\0")
    else:
        conf = configparser.ConfigParser(interpolation=None)
        with (args.base / "configs/pgbackrest.conf").open() as stream:
            conf.read_file(stream)
        c = conf['global']
        endpoint = 'https://' + c['repo1-s3-endpoint']
        region, bucket, access, secret, password = (c[k] for k in ('repo1-s3-region','repo1-s3-bucket','repo1-s3-key','repo1-s3-key-secret','repo1-cipher-pass'))
    archive = Archive(S3(endpoint, region, access, secret), bucket, password, args.slug)
    roots = [Path(d.strip()) for d in args.dirs.split(",") if d.strip()]
    nodekey = f"sets/{args.id}/node-{args.node}"
    objkey = f"sets/{args.id}/objects"
    if args.action == 'capture':
        if not roots:
            raise ValueError("no volume roots configured")
        capture(archive, nodekey, roots)
    elif args.action == 'stable':
        if inventory(roots) != json.loads(archive.get(nodekey))["stat"]:
            raise SnapshotChanged("SeaweedFS changed at the PostgreSQL recovery boundary")
    elif args.action in ('objects', 'check-objects'):
        evidence = object_evidence(args.base, args.port)
        if args.action == 'objects':
            archive.put(objkey, packed(evidence))
        elif evidence != json.loads(archive.get(objkey)):
            raise ValueError("object contents, versions, delete markers or WORM retention differ from the snapshot")
    elif args.action == 'commit':
        if args.nodes < 1 or not re.fullmatch(r"[0-9A-Z_-]+", args.label or ""):
            raise ValueError("invalid database backup set")
        at = timestamp(args.at)
        point = dict(id=args.id, at=at, label=args.label, nodes=args.nodes)
        archive.put("points/" + at + "_" + args.id, packed(point))
        print(at)
    elif args.action == 'list':
        for key in sorted(archive.releases(), reverse=True):
            point = json.loads(archive.get(key))
            print(f"{point['at']}  {point['label']}  {point['nodes']} nodes  {point['id']}")
    elif args.action == 'select':
        target = timestamp(args.at) if args.at else None
        keys = sorted(archive.releases(), reverse=True)
        matches = [k for k in keys if not target or k.startswith("points/"+target+"_")]
        if not matches:
            points = ", ".join(k.split("/", 1)[1].rsplit("_",1)[0] for k in keys[:8])
            raise ValueError("no matching complete file/PG recovery point; available UTC points: " + (points or "none (legacy metadata-only backups cannot restore files)"))
        point = json.loads(archive.get(matches[0]))
        if not re.fullmatch(r"[0-9a-f]{32}", point["id"]) or not re.fullmatch(r"[0-9A-Z_-]+", point["label"]) or point["nodes"] != args.nodes:
            raise ValueError("snapshot topology or backup label does not match")
        print(point["id"], point["label"], point["at"])
    elif args.action == 'verify':
        for index in range(1, args.nodes+1):
            materialize(archive, f"sets/{args.id}/node-{index}", [], False)
        json.loads(archive.get(objkey))
    elif args.action == 'destination':
        prepare_destination(archive, nodekey, roots, json.loads(archive.get(nodekey)))
    elif args.action == 'restore':
        materialize(archive, nodekey, roots, True)


if __name__ == "__main__":
    try:
        main()
    except SnapshotChanged as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(75)
    except Exception as exc:
        print("Snapshot failed: " + str(exc), file=sys.stderr)
        sys.exit(1)
