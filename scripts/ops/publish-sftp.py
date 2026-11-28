#!/usr/bin/env python3
"""Publish an SFTP object after checking the staged download against the local file."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import secrets
import subprocess
import sys
import tempfile


def quoted(path):
    text = str(path)
    if any(ord(char) < 32 for char in text):
        raise ValueError("control characters are unsupported in an SFTP batch path")
    return '"' + "".join(("\\" + char) if char in '\\"*?[]' else char for char in text) + '"'


def fingerprint(path):
    length = 0
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            length += len(chunk)
            checksum.update(chunk)
    return length, checksum.hexdigest()


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("host", help="SSH configuration alias or user@DNS-name")
    args.add_argument("source", type=Path)
    args.add_argument("destination", help="absolute destination in /work or an external virtual folder")
    args.add_argument("-F", "--ssh-config", type=Path, help="OpenSSH configuration file")
    args.add_argument("-P", "--port", type=int)
    args.add_argument("-i", "--identity", type=Path)
    args.add_argument("--known-hosts", type=Path)
    opt = args.parse_args()
    dest = PurePosixPath(opt.destination)
    if not dest.is_absolute() or len(dest.parts) < 3 or '..' in dest.parts or dest.parts[1] == 'worm':
        args.error("destination must be a file in a writable virtual folder supporting rename")
    if not opt.host or opt.host.startswith('-') or any(char.isspace() for char in opt.host):
        args.error("invalid SSH destination")
    cmd = ['sftp', '-q', '-b', '-', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes']
    if opt.ssh_config:
        cmd += ['-F', str(opt.ssh_config)]
    if opt.port:
        cmd += ['-P', str(opt.port)]
    if opt.identity:
        cmd += ['-i', str(opt.identity)]
    if opt.known_hosts:
        cmd += ['-o', 'UserKnownHostsFile=' + str(opt.known_hosts.resolve())]
    cmd.append(opt.host)
    def transfer(commands):
        subprocess.run(cmd, input=commands + '\n', text=True, check=True, stdout=subprocess.DEVNULL)

    source = opt.source.resolve()
    expected = fingerprint(source)
    staging = dest.parent / ('.lv-upload-' + secrets.token_hex(16))
    with tempfile.TemporaryDirectory(prefix='lv-publish-') as directory:
        check = Path(directory) / 'readback'
        try:
            transfer('put ' + quoted(source) + ' ' + quoted(staging) + '\nget ' + quoted(staging) + ' ' + quoted(check))
            if fingerprint(check) != expected:
                raise ValueError("staged upload failed size/SHA-256 verification")
            check.unlink()
            transfer('rename ' + quoted(staging) + ' ' + quoted(dest) + '\nget ' + quoted(dest) + ' ' + quoted(check))
            if fingerprint(check) != expected:
                raise ValueError("published upload failed size/SHA-256 verification")
        finally:
            subprocess.run(cmd, input='-rm ' + quoted(staging) + '\n', text=True, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'{expected[1]}  {expected[0]} bytes  {dest}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print('Publication failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
