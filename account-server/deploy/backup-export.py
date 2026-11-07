#!/usr/bin/env python3
"""Restricted SSH forced-command for a private Mac offsite backup receiver.

Install root-owned 0755 and authorize a dedicated SSH key with:
restrict,command="/usr/bin/python3 /opt/bojiclub-account/deploy/backup-export.py" ssh-ed25519 PUBLIC_KEY
No installation or authorization is performed by this program. The only protocol
commands are manifest, archive NAME SHA256, key NAME SHA256, and
ack NAME SHA256 KEY_SHA256. Commands, paths, config and credentials cannot be
supplied through arguments or environment. Never log stdout: key emits a secret
only into the authenticated SSH transport.
"""
from __future__ import annotations
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

STATE = Path('/root/bojiclub-rebuild-v59')
ARCHIVES = Path('/root/bojiclub-backups')
OWNER_UID = 0
NAME_RE = re.compile(r'bojiclub-full-[0-9]{8}T[0-9]{6}Z(?:-[0-9a-f]{8})?\.boji\Z')
SHA_RE = re.compile(r'[0-9a-f]{64}\Z')
MAX_ARCHIVE = 2*1024**4  # Bound the protocol, without imposing a tiny photo quota.


class ExportError(Exception):
    pass


def secure_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != OWNER_UID or info.st_mode & 0o022:
        raise ExportError('unsafe directory')
    # Fixed absolute roots must never be redirected via symlinked ancestors.
    if path.resolve() != path.absolute():
        raise ExportError('redirected directory')


def open_fixed(path, private=False, maximum=None):
    secure_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != OWNER_UID or info.st_mode & (0o077 if private else 0o022):
            raise ExportError('unsafe file')
        if info.st_nlink != 1 or (maximum is not None and info.st_size > maximum):
            raise ExportError('invalid file')
        return os.fdopen(fd, 'rb')
    except BaseException:
        os.close(fd)
        raise


def digest_stream(stream):
    digest = hashlib.sha256()
    while chunk := stream.read(1024*1024):
        digest.update(chunk)
    stream.seek(0)
    return digest.hexdigest()


def load_current():
    with open_fixed(STATE/'backup-result.json', maximum=65536) as source:
        record = json.load(source)
    if not isinstance(record, dict) or not isinstance(record.get('path'), str):
        raise ExportError('missing completed backup')
    path = Path(record['path'])
    if path.parent != ARCHIVES or not NAME_RE.fullmatch(path.name):
        raise ExportError('invalid archive name')
    archive = open_fixed(path, private=True, maximum=MAX_ARCHIVE)
    try:
        size = os.fstat(archive.fileno()).st_size
        if size <= 55 or archive.read(11) != b'BOJIBACKUP2' or record.get('bytes') != size:
            raise ExportError('incomplete archive')
        archive.seek(0)
        digest = digest_stream(archive)
        with open_fixed(STATE/'backup-password', private=True, maximum=4096) as source:
            key = source.read().decode('utf-8').strip().encode('utf-8')
        key_sha = hashlib.sha256(key).hexdigest()
        if len(key) < 24 or key_sha[:16] != record.get('key_fingerprint'):
            raise ExportError('key unavailable for current archive')
        created = record.get('created_at_utc')
        if not isinstance(created, str) or not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z', created):
            raise ExportError('invalid timestamp')
        manifest = {'schema_version': 1, 'archive': path.name, 'bytes': size, 'sha256': digest,
                    'created_at_utc': created, 'encryption': 'AES-256-GCM',
                    'key_fingerprint': key_sha[:16], 'key_sha256': key_sha}
        return manifest, archive, key
    except BaseException:
        archive.close()
        raise


def parse_command(value):
    # Deliberately avoid a shell or shlex interpretation: no quotes, metacharacters,
    # whitespace variants, paths, options, or trailing commands are protocol input.
    if not isinstance(value, str) or len(value) > 512:
        raise ExportError('invalid command')
    parts = value.split(' ')
    if parts == ['manifest']:
        return parts
    if len(parts) not in (3, 4) or parts[0] not in ('archive', 'key', 'ack'):
        raise ExportError('invalid command')
    if len(parts) != (4 if parts[0] == 'ack' else 3):
        raise ExportError('invalid argument count')
    if not NAME_RE.fullmatch(parts[1]) or not SHA_RE.fullmatch(parts[2]):
        raise ExportError('invalid identity')
    if parts[0] == 'ack' and not SHA_RE.fullmatch(parts[3]):
        raise ExportError('invalid key identity')
    return parts


def atomic_ack(value):
    secure_directory(STATE)
    target = STATE/'offsite-mac-ack.json'
    if target.is_symlink():
        raise ExportError('unsafe acknowledgement')
    fd, temporary = tempfile.mkstemp(prefix='.offsite-mac-ack-', dir=STATE)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(value, output)
            output.flush(); os.fsync(output.fileno())
        os.replace(temporary, target)
        directory_fd = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
    finally:
        Path(temporary).unlink(missing_ok=True)


def serve(command, output):
    parts = parse_command(command)
    manifest, archive, key = load_current()
    try:
        if parts[0] != 'manifest' and (parts[1] != manifest['archive'] or parts[2] != manifest['sha256']):
            raise ExportError('backup changed; fetch manifest again')
        if parts[0] == 'archive':
            while chunk := archive.read(1024*1024): output.write(chunk)
        elif parts[0] == 'key':
            output.write(key)  # Never print/decode in the caller or logs.
        elif parts[0] == 'ack':
            if parts[3] != manifest['key_sha256']:
                raise ExportError('key verification missing')
            ack = {**manifest, 'confirmed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                   'target': 'private_mac', 'state': 'receiver_verified', 'restore_verified': False}
            atomic_ack(ack)
            output.write(json.dumps({'schema_version': 1, 'state': 'acknowledged', 'archive': manifest['archive'], 'sha256': manifest['sha256']}).encode())
        else:
            output.write(json.dumps(manifest).encode())
        output.flush()
    finally:
        archive.close()


def main():
    try:
        if len(sys.argv) != 1:
            raise ExportError('arguments not allowed')
        serve(os.environ.get('SSH_ORIGINAL_COMMAND', ''), sys.stdout.buffer)
        return 0
    except (ExportError, OSError, ValueError, TypeError, UnicodeError):
        # A static error avoids leaking a credential, path, record, or SSH command.
        print('BACKUP_EXPORT_DENIED: request unavailable or rejected', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
