#!/usr/bin/env python3
"""Pull the latest encrypted Boji backup onto the user's private Mac.

No real configuration, SSH authorization, or launchd installation is created.
Use a private config with identity_file and known_hosts_file absolute paths.
The server is fixed to 117.50.119.49. StrictHostKeyChecking is always enabled.
Output contains status metadata only; SSH stderr and backup keys are never logged.
Run once at login/startup and hourly while awake; a sleeping/offline Mac cannot
receive a backup. The next successful run fetches the newest retained package.
"""
from __future__ import annotations
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path('/Users/a01/Documents/BOJI_CLUB_Backups')
SERVER = '117.50.119.49'
SSH = '/usr/bin/ssh'
NAME_RE = re.compile(r'bojiclub-full-[0-9]{8}T[0-9]{6}Z(?:-[0-9a-f]{8})?\.boji\Z')
SHA_RE = re.compile(r'[0-9a-f]{64}\Z')
MAX_ARCHIVE = 2*1024**4


class PullError(Exception):
    pass


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def private_directory(path):
    if not path.is_absolute() or path.resolve() != path.absolute():
        raise PullError('unsafe local directory')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise PullError('unsafe local ownership')
    os.chmod(path, 0o700)


def private_file(path):
    if not path.is_absolute() or path.resolve() != path.absolute():
        raise PullError('unsafe private file')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise PullError('unsafe private file')
    return path


def configure(path):
    with private_file(path).open() as source:
        value = json.load(source)
    if not isinstance(value, dict) or set(value) != {'identity_file', 'known_hosts_file'}:
        raise PullError('invalid private config')
    result = {}
    for key in ('identity_file', 'known_hosts_file'):
        if not isinstance(value[key], str):
            raise PullError('invalid private config')
        result[key] = private_file(Path(value[key]))
    if result['known_hosts_file'].stat().st_size == 0:
        raise PullError('host fingerprint pending')
    return result


def ssh_command(config, command):
    return [SSH, '-F', '/dev/null', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
            '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile='+str(config['known_hosts_file']),
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'UpdateHostKeys=no', '-o', 'CheckHostIP=yes',
            '-o', 'HostKeyAlias='+SERVER, '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=2', '-o', 'ControlMaster=no', '-o', 'ProxyCommand=none',
            '-o', 'ClearAllForwardings=yes', '-i', str(config['identity_file']), 'root@'+SERVER, command]


def receive(config, command, target, maximum, expected_size=None, timeout=120):
    """Stream private SSH stdout to a temp file; cap before writing each chunk."""
    process = subprocess.Popen(ssh_command(config, command), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    import selectors
    import time
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    total, digest, deadline = 0, hashlib.sha256(), time.monotonic()+timeout
    try:
        while True:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise PullError('transfer timeout')
            if not selector.select(min(remaining, 1)):
                continue
            chunk = os.read(process.stdout.fileno(), 1024*1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise PullError('transfer too large')
            target.write(chunk); digest.update(chunk)
        if process.wait(timeout=max(.1, deadline-time.monotonic())) != 0:
            raise PullError('SSH transfer unavailable')
        if expected_size is not None and total != expected_size:
            raise PullError('archive size mismatch')
        return total, digest.hexdigest()
    except BaseException:
        process.kill(); process.wait()
        raise
    finally:
        selector.close()
        process.stdout.close()


def small_response(config, command, maximum=65536):
    import io
    output = io.BytesIO()
    receive(config, command, output, maximum)
    return output.getvalue()


def manifest_value(raw):
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get('schema_version') != 1:
        raise PullError('invalid manifest')
    name, size = value.get('archive'), value.get('bytes')
    if not isinstance(name, str) or not NAME_RE.fullmatch(name) or type(size) is not int or not 55 < size <= MAX_ARCHIVE:
        raise PullError('invalid archive metadata')
    if value.get('encryption') != 'AES-256-GCM':
        raise PullError('unencrypted archive refused')
    for key in ('sha256', 'key_sha256'):
        if not isinstance(value.get(key), str) or not SHA_RE.fullmatch(value[key]):
            raise PullError('invalid digest')
    if value.get('key_fingerprint') != value['key_sha256'][:16]:
        raise PullError('invalid key fingerprint')
    if not isinstance(value.get('created_at_utc'), str) or not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z', value['created_at_utc']):
        raise PullError('invalid backup timestamp')
    # Publish only protocol keys, never arbitrary server fields.
    return {k: value[k] for k in ('schema_version', 'archive', 'bytes', 'sha256', 'encryption', 'key_fingerprint', 'key_sha256', 'created_at_utc')}


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.metadata-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(value, output, ensure_ascii=False)
            output.flush(); os.fsync(output.fileno())
        if path.is_symlink():
            raise PullError('unsafe metadata file')
        os.replace(temporary, path); sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def digest_file(path):
    digest = hashlib.sha256()
    with private_file(path).open('rb') as source:
        while chunk := source.read(1024*1024): digest.update(chunk)
    return digest.hexdigest()


def existing_valid(path, expected_digest, expected_size=None):
    if not path.exists() and not path.is_symlink():
        return False
    # Refuse an unsafe preexisting object instead of replacing it silently.
    private_file(path)
    return (expected_size is None or path.stat().st_size == expected_size) and digest_file(path) == expected_digest


def download_archive(config, manifest, directory):
    target = directory/manifest['archive']
    if existing_valid(target, manifest['sha256'], manifest['bytes']):
        with target.open('rb') as source:
            if source.read(11) != b'BOJIBACKUP2': raise PullError('archive header invalid')
        return target
    fd, temporary = tempfile.mkstemp(prefix='.encrypted-', dir=directory)
    try:
        with os.fdopen(fd, 'w+b') as output:
            os.fchmod(output.fileno(), 0o600)
            _, digest = receive(config, 'archive '+manifest['archive']+' '+manifest['sha256'], output,
                                manifest['bytes'], expected_size=manifest['bytes'], timeout=3600)
            output.flush(); os.fsync(output.fileno()); output.seek(0)
            if digest != manifest['sha256'] or output.read(11) != b'BOJIBACKUP2':
                raise PullError('archive verification failed')
        # A different payload under the same immutable name is never overwritten.
        if target.exists() or target.is_symlink():
            raise PullError('archive filename collision; old copy preserved')
        os.link(temporary, target)
        Path(temporary).unlink(); sync_directory(directory)
        return target
    finally:
        Path(temporary).unlink(missing_ok=True)


def download_key(config, manifest, directory):
    target = directory/('backup-key-'+manifest['key_fingerprint']+'.key')
    if existing_valid(target, manifest['key_sha256']):
        return target
    key = small_response(config, 'key '+manifest['archive']+' '+manifest['sha256'], maximum=4096)
    if len(key) < 24 or hashlib.sha256(key).hexdigest() != manifest['key_sha256']:
        raise PullError('key verification failed')
    fd, temporary = tempfile.mkstemp(prefix='.key-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(key); output.flush(); os.fsync(output.fileno())
        if target.exists() or target.is_symlink():
            raise PullError('key filename collision; old key preserved')
        os.link(temporary, target)
        Path(temporary).unlink(); sync_directory(directory)
        return target
    finally:
        Path(temporary).unlink(missing_ok=True)
        key = None


def pull(config):
    metadata = ROOT/'metadata'
    manifest = manifest_value(small_response(config, 'manifest'))
    download_archive(config, manifest, ROOT/'archives')
    download_key(config, manifest, ROOT/'keys')
    local_record = {**manifest, 'local_verified_at': stamp(), 'remote_ack': 'pending', 'restore_verified': False}
    atomic_json(metadata/(manifest['archive']+'.json'), local_record)
    # Acknowledgement is permitted only after both private files are fsynced and verified.
    try:
        ack = json.loads(small_response(config, 'ack '+manifest['archive']+' '+manifest['sha256']+' '+manifest['key_sha256']))
        if not isinstance(ack, dict) or ack.get('state') != 'acknowledged' or ack.get('archive') != manifest['archive'] or ack.get('sha256') != manifest['sha256']:
            raise PullError('acknowledgement rejected')
    except (OSError, ValueError, PullError, subprocess.SubprocessError):
        return {'schema_version': 1, 'checked_at': stamp(), 'state': 'copied_ack_pending',
                'archive': manifest['archive'], 'message': '加密包与密钥已在本机校验保存，服务器回执尚待确认。'}
    local_record['remote_ack'] = 'acknowledged'
    atomic_json(metadata/(manifest['archive']+'.json'), local_record)
    atomic_json(metadata/'latest-good.json', local_record)
    return {'schema_version': 1, 'checked_at': stamp(), 'state': 'succeeded', 'archive': manifest['archive'],
            'message': '最新加密包与密钥已分别保存并校验；服务器已确认回执。'}


def cleanup_staging():
    # With the process lock held, discard only this tool's abandoned private
    # staging names. This also resolves a crash between link and temp unlink.
    for directory, prefix in ((ROOT/'archives', '.encrypted-'), (ROOT/'keys', '.key-'), (ROOT/'metadata', '.metadata-')):
        for path in directory.glob(prefix+'*'):
            if not re.fullmatch(re.escape(prefix)+r'[a-z0-9_]{8}', path.name):
                continue
            info = path.lstat()
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077:
                path.unlink()
        sync_directory(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'metadata'/'pull-config.json')
    args = parser.parse_args()
    try:
        for path in (ROOT, ROOT/'archives', ROOT/'keys', ROOT/'metadata'):
            private_directory(path)
        lock_path = ROOT/'metadata'/'pull.lock'
        if lock_path.is_symlink(): raise PullError('unsafe lock')
        with lock_path.open('a') as lock:
            os.chmod(lock_path, 0o600)
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return 0
            try:
                cleanup_staging()
                config = configure(args.config)
                result = pull(config)
            except (OSError, ValueError, TypeError, PullError, subprocess.SubprocessError):
                result = {'schema_version': 1, 'checked_at': stamp(), 'state': 'pending',
                          'message': '尚未完成本次接收，请核对网络、SSH授权、已核实的主机指纹和私有配置；原有好包与密钥保留。'}
            atomic_json(ROOT/'metadata'/'pull-status.json', result)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['state'] == 'succeeded' else 1
    except (OSError, ValueError, TypeError, PullError):
        print('备份接收尚未完成：请核对私有目录和文件权限。', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
