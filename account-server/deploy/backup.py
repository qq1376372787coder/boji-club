#!/usr/bin/env python3
"""Boji Club encrypted full-recovery backup.

FIX-009 / AUD-009: the recovery set must include the Apple Sign in private key
and every scheduler unit, not just the application directories. The password is
read from a root-only file and is never written into the archive or logs. Store
a second copy of that password off the server; without it the archive cannot be
opened.

Usage (production paths are defaults):
    python3 backup.py --dry-run
    python3 backup.py
Environment:
    BOJI_BACKUP_ROOT       state directory (default /root/bojiclub-rebuild-v59)
    BOJI_BACKUP_DEST       encrypted archive directory (default /root/bojiclub-backups)
    BOJI_BACKUP_PASSWORD_FILE  default <root>/backup-password
    BOJI_MYSQL_DATABASE    default bojiclub
    BOJI_AI_SQLITE         default /opt/bojiclub-ai/.data/jobs.sqlite3
    BOJI_OFFSITE_CMD       optional shell command receiving the archive path as $1
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import re
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
except ImportError:  # pragma: no cover - deployment dependency check
    Cipher = None

REQUIRED_PATHS = [
    "/opt/bojiclub-account",
    "/opt/bojiclub-ai",
    "/etc/bojiclub/apple-signin.p8",
    "/etc/nginx",
    "/etc/php-fpm.d/www.conf",
    "/etc/systemd/system/bojiclub-ai.service",
    "/etc/systemd/system/bojiclub-account-deletions.service",
    "/etc/systemd/system/bojiclub-account-deletions.timer",
    "/etc/systemd/system/bojiclub-backup.service",
    "/etc/systemd/system/bojiclub-backup.timer",
]
OPTIONAL_UNITS = [
    "/etc/bojiclub",
    "/root/bojiclub-rebuild-v59/backup.py",
    "/root/bojiclub-rebuild-v59/restore.py",
    "/etc/systemd/system/bojiclub-club-automation.service",
    "/etc/systemd/system/bojiclub-club-automation.timer",
    "/etc/systemd/system/bojiclub-club-push.service",
    "/etc/systemd/system/bojiclub-club-push.timer",
    "/etc/systemd/system/bojiclub-ip-cert-renew.service",
    "/etc/systemd/system/bojiclub-ip-cert-renew.timer",
    "/etc/my.cnf",
    "/etc/my.cnf.d",
    "/etc/letsencrypt-bojiclub-ip",
]
NEVER_ARCHIVE = ("__pycache__", ".pyc", "jobs.sqlite3-wal", "jobs.sqlite3-shm")


# Only non-sensitive operational metadata is published for the web dashboard.
LAST_FAILURE = 'backup_failed'
STAGE = 'preflight'

def status_file() -> Path:
    return Path(os.environ.get('BOJI_BACKUP_STATUS_FILE', '/opt/bojiclub-account/runtime/backup-status.json'))

def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}

def write_status(value: dict) -> None:
    path = status_file()
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.backup-status-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as target:
            json.dump(value, target, ensure_ascii=False)
            target.flush(); os.fsync(target.fileno())
            os.fchmod(target.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)

def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()

def unit_status(unit: str) -> dict:
    if source_root() != Path('/'):
        return {}  # Never read host services during an isolated drill.
    try:
        result = subprocess.run(['systemctl', 'show', unit, '--no-pager',
            '--property=LoadState,ActiveState,SubState,UnitFileState,Result,NextElapseUSecRealtime,LastTriggerUSec'],
            capture_output=True, text=True, timeout=8, env={**os.environ, 'TZ':'UTC'})
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    except (OSError, subprocess.TimeoutExpired):
        return {}

def refresh_status(value: dict | None = None) -> dict:
    root = Path(os.environ.get('BOJI_BACKUP_ROOT', '/root/bojiclub-rebuild-v59'))
    dest = Path(os.environ.get('BOJI_BACKUP_DEST', '/root/bojiclub-backups'))
    state = read_json(status_file()) if value is None else value
    record = read_json(root / 'backup-result.json')
    archive = Path(str(record.get('path', '')))
    # Do not trust an arbitrary path from a stale/private result record.
    valid_path = bool(record.get('path')) and archive.parent.resolve() == dest.resolve() and bool(re.fullmatch(r'bojiclub-full-[0-9TZ]+(?:-[0-9a-f]{8})?[.]boji', archive.name))
    exists = valid_path and archive.is_file() and archive.stat().st_size > 55
    if record and exists:
        state.update(last_success=record.get('created_at_utc'), bytes=archive.stat().st_size,
            local_archive_present=True, encrypted=True, offsite_copy=record.get('offsite_copy', 'pending'),
            recovery_items=record.get('members', 0))
        archive_sha=record.get('sha256') or sha256_file(archive)
        ack=read_json(root/'offsite-mac-ack.json')
        matches=(ack.get('state')=='receiver_verified' and ack.get('archive')==archive.name and ack.get('sha256')==archive_sha and ack.get('bytes')==archive.stat().st_size and ack.get('key_sha256','')[:16]==record.get('key_fingerprint'))
        state['offsite_configured']=bool((root/'offsite-mac-enabled').exists() or os.environ.get('BOJI_OFFSITE_CMD'))
        if matches:
            state.update(offsite_copy='ok',offsite_target='private_mac',offsite_confirmed_at=ack.get('confirmed_at'))
        else:
            state.pop('offsite_confirmed_at',None)
        drill_path=Path(os.environ.get('BOJI_RESTORE_STATUS_FILE',str(status_file().parent/'restore-drill-status.json')))
        drill=read_json(drill_path)
        state['restore_verified']=(drill.get('status')=='passed' and drill.get('archive')==archive.name and drill.get('sha256')==archive_sha and drill.get('isolation',{}).get('state')=='passed' and drill.get('cleanup_complete') is True)
        state['restore_checked_at']=drill.get('checked_at') if state['restore_verified'] else None
        if 'state' not in state: state['state']='succeeded'
    else:
        state['local_archive_present']=False
        if record and state.get('state')!='running':
            state.update(state='failed', last_error_code='archive_missing')
        state['restore_verified']=False
        state['offsite_copy']='pending'
    timer=unit_status('bojiclub-backup.timer'); service=unit_status('bojiclub-backup.service')
    if state.get('state')=='running' and service.get('LoadState')=='loaded' and service.get('ActiveState') not in ('active','activating'):
        state.update(state='failed',last_error_code='interrupted')
    state.update(schema_version=1, checked_at=utc_now(), retention_copies=14,
        schedule={'available':timer.get('LoadState')=='loaded',
            'active':timer.get('ActiveState')=='active', 'enabled':timer.get('UnitFileState') in ('enabled','enabled-runtime'),
            'next_run_utc':timer.get('NextElapseUSecRealtime'), 'last_trigger_utc':timer.get('LastTriggerUSec')},
        service={'state':service.get('ActiveState','unknown'), 'result':service.get('Result','unknown')})
    state.setdefault('state','unknown')
    state.setdefault('restore_verified',False)
    write_status(state)
    return state


def fail(message: str) -> "NoReturn":
    global LAST_FAILURE
    LAST_FAILURE = ('dependency_missing' if 'cryptography' in message else
        'password_missing' if 'password' in message else
        'recovery_path_missing' if 'recovery paths' in message else
        'database_dump_failed' if 'mysqldump' in message else
        'ai_database_missing' if 'AI SQLite' in message else 'backup_failed')
    print("BACKUP_FAILED: " + message, file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_root() -> Path:
    # Isolated recovery drills can point at a fake root; production uses /.
    return Path(os.environ.get("BOJI_BACKUP_SOURCE_ROOT", "/"))


def source_path(path: str) -> Path:
    root = source_root()
    return Path(path) if root == Path("/") else root / path.lstrip("/")


def add_path(tar: tarfile.TarFile, path: Path, members: list[dict]) -> None:
    logical = path if source_root() == Path("/") else Path("/") / path.relative_to(source_root())
    if not path.exists():
        return
    if path.is_symlink():
        # Keep the link itself; do not follow an attacker-controlled target.
        info = tar.gettarinfo(str(path), arcname=str(logical).lstrip("/"))
        tar.addfile(info)
        members.append({"path": str(logical), "kind": "symlink", "target": os.readlink(path)})
        return
    filter_fn = (lambda m: None if any(part in m.name for part in NEVER_ARCHIVE) else m)
    tar.add(str(path), arcname=str(logical).lstrip("/"), filter=filter_fn, recursive=True)
    if path.is_file():
        members.append({"path": str(logical), "kind": "file", "mode": oct(path.stat().st_mode & 0o777),
                        "size": path.stat().st_size, "sha256": sha256_file(path)})
    else:
        members.append({"path": str(logical), "kind": "directory"})


def run_dry_run(paths: list[str], optional: list[str]) -> int:
    missing = [path for path in paths if not source_path(path).exists()]
    print("REQUIRED_PRESENT " + str(len(paths) - len(missing)) + "/" + str(len(paths)))
    for path in missing:
        print("REQUIRED_MISSING " + path)
    for path in optional:
        if source_path(path).exists():
            print("OPTIONAL_PRESENT " + path)
    return 1 if missing else 0


def backup(args: argparse.Namespace) -> int:
    global STAGE
    root = Path(os.environ.get("BOJI_BACKUP_ROOT", "/root/bojiclub-rebuild-v59"))
    dest = Path(os.environ.get("BOJI_BACKUP_DEST", "/root/bojiclub-backups"))
    password_file = Path(os.environ.get("BOJI_BACKUP_PASSWORD_FILE", str(root / "backup-password")))
    paths = list(REQUIRED_PATHS)
    scheduler_dir=source_path('/etc/systemd/system')
    installed_units=['/etc/systemd/system/'+p.name for pattern in ['bojiclub-*.service','bojiclub-*.timer','operations-alerts.service','operations-alerts.timer'] for p in scheduler_dir.glob(pattern)]
    optional = sorted(set(p for p in OPTIONAL_UNITS+installed_units if source_path(p).exists())-set(paths))
    if args.dry_run:
        return run_dry_run(paths, optional)
    if Cipher is None:
        fail("python cryptography is required on the backup host")
    if not password_file.is_file():
        fail("backup password file is missing")
    password = password_file.read_text().strip()
    if len(password) < 24:
        fail("backup password is too short")
    missing = [path for path in paths if not source_path(path).exists()]
    if missing:
        fail("required recovery paths missing: " + ", ".join(missing))
    if not source_path(os.environ.get('BOJI_AI_SQLITE', '/opt/bojiclub-ai/.data/jobs.sqlite3')).is_file():
        fail('AI SQLite database is missing')
    dest.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="boji-backup-", dir=root))
    plain = work / "recovery.tar.gz"
    output = dest / ("bojiclub-full-" + stamp + "-" + os.urandom(4).hex() + ".boji")
    members: list[dict] = []
    try:
        database = os.environ.get("BOJI_MYSQL_DATABASE", "bojiclub")
        dump_path = work / "database.sql"
        dump_command = ["mysqldump"]
        if os.environ.get("BOJI_MYSQL_SOCKET"):
            dump_command.append("--socket=" + os.environ["BOJI_MYSQL_SOCKET"])
        dump_command += ["--single-transaction", "--routines", "--triggers", database]
        STAGE='database'
        with dump_path.open("wb") as handle:
            result = subprocess.run(
                dump_command, stdout=handle, stderr=subprocess.PIPE, timeout=180,
            )
        if result.returncode != 0:
            fail("mysqldump failed; no archive was written")
        members.append({"path": "database.sql", "kind": "database", "sha256": sha256_file(dump_path)})
        ai_sqlite = source_path(os.environ.get("BOJI_AI_SQLITE", "/opt/bojiclub-ai/.data/jobs.sqlite3"))
        if ai_sqlite.is_file():
            copy = work / "ai-jobs.sqlite3"
            with sqlite3.connect(str(ai_sqlite)) as source, sqlite3.connect(str(copy)) as target:
                source.backup(target)
            members.append({"path": "ai-jobs.sqlite3", "kind": "sqlite", "sha256": sha256_file(copy)})
        STAGE='archive'
        with tarfile.open(plain, "w:gz") as tar:
            tar.add(str(dump_path), arcname="database.sql")
            if (work / "ai-jobs.sqlite3").exists():
                tar.add(str(work / "ai-jobs.sqlite3"), arcname="ai-jobs.sqlite3")
            archive_roots = paths + optional
            # Config directories include signing keys; do not archive their
            # individually required children twice.
            for path in archive_roots:
                if any(Path(parent) in Path(path).parents for parent in archive_roots):
                    continue
                add_path(tar, source_path(path), members)
            # The password itself is deliberately not in the archive. The
            # fingerprint proves which key was used without disclosing it.
            fingerprint = hashlib.sha256(password.encode()).hexdigest()[:16]
            manifest = {
                "version": 2,
                "created_at": stamp,
                "host": os.uname().nodename,
                "key_fingerprint": fingerprint,
                "includes": members,
                "restore_notes": [
                    "Use an off-server copy of the backup password; it is not in this archive.",
                    "Install systemd units and reload daemons before starting services.",
                    "Verify MySQL and AI SQLite before switching traffic.",
                ],
            }
            encoded = json.dumps(manifest, ensure_ascii=False, indent=2).encode()
            info = tarfile.TarInfo("recovery-manifest.json")
            info.size = len(encoded); info.mode = 0o600
            import io
            tar.addfile(info, io.BytesIO(encoded))
        STAGE='encrypt'
        salt = os.urandom(16); nonce = os.urandom(12)
        key = Scrypt(salt=salt, length=32, n=32768, r=8, p=1).derive(password.encode())
        encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
        with plain.open("rb") as source, output.open("wb") as target:
            target.write(b"BOJIBACKUP2" + salt + nonce)
            while chunk := source.read(1024 * 1024):
                target.write(encryptor.update(chunk))
            target.write(encryptor.finalize()); target.write(encryptor.tag)
        output.chmod(0o600)
        STAGE='offsite'
        offsite = "pending"
        offsite_command = os.environ.get("BOJI_OFFSITE_CMD", "")
        if offsite_command:
            try:
                result = subprocess.run(["sh", "-c", offsite_command + ' "$1"', "boji-offsite", str(output)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=900)
                offsite = "ok" if result.returncode == 0 else "failed"
            except (OSError, subprocess.TimeoutExpired):
                # The encrypted local recovery set remains valid if offsite copy times out.
                offsite = "failed"
        result_value = {
            "path": str(output), "bytes": output.stat().st_size, "sha256": sha256_file(output),
            "encrypted": "AES-256-GCM with scrypt key derivation",
            "created_at_utc": stamp,
            "key_fingerprint": hashlib.sha256(password.encode()).hexdigest()[:16],
            "members": len(members), "offsite_copy": offsite,
        }
        (root / "backup-result.json").write_text(json.dumps(result_value, indent=2))
        print(json.dumps(result_value), flush=True)
        old = sorted(dest.glob("bojiclub-full-*.boji"), key=lambda p: p.name, reverse=True)[14:]
        for path in old:
            if path.resolve().parent == dest.resolve():
                path.unlink()
        return 0
    finally:
        if work.resolve().parent == root.resolve() and work.name.startswith("boji-backup-"):
            shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Encrypted Boji Club recovery backup")
    parser.add_argument("--dry-run", action="store_true", help="only report recovery-path coverage")
    parser.add_argument('--status-only', action='store_true', help='publish safe backup and scheduler metadata; never starts a backup')
    args = parser.parse_args()
    if args.status_only:
        state=refresh_status()
        print(json.dumps({'status_published':True,'backup_state':state['state']}))
        return 0
    if args.dry_run:return backup(args)
    state=read_json(status_file())
    state.update(state='running', last_attempt=utc_now(), last_error_code=None, restore_verified=False)
    write_status(state)
    try:
        result=backup(args)
    except BaseException:
        state.update(state='failed', last_error_code=LAST_FAILURE, failed_stage=STAGE)
        refresh_status(state)
        raise
    state.update(state='succeeded', last_error_code=None, failed_stage=None)
    refresh_status(state)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
