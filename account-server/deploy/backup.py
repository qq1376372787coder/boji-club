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


def fail(message: str) -> "NoReturn":
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
    if not path.exists():
        return
    if path.is_symlink():
        # Keep the link itself; do not follow an attacker-controlled target.
        info = tar.gettarinfo(str(path), arcname=str(path).lstrip("/"))
        tar.addfile(info)
        members.append({"path": str(path), "kind": "symlink", "target": os.readlink(path)})
        return
    filter_fn = (lambda m: None if any(part in m.name for part in NEVER_ARCHIVE) else m)
    tar.add(str(path), arcname=str(path).lstrip("/"), filter=filter_fn, recursive=True)
    if path.is_file():
        members.append({"path": str(path), "kind": "file", "mode": oct(path.stat().st_mode & 0o777),
                        "size": path.stat().st_size, "sha256": sha256_file(path)})
    else:
        members.append({"path": str(path), "kind": "directory"})


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
    root = Path(os.environ.get("BOJI_BACKUP_ROOT", "/root/bojiclub-rebuild-v59"))
    dest = Path(os.environ.get("BOJI_BACKUP_DEST", "/root/bojiclub-backups"))
    password_file = Path(os.environ.get("BOJI_BACKUP_PASSWORD_FILE", str(root / "backup-password")))
    paths = list(REQUIRED_PATHS)
    optional = [p for p in OPTIONAL_UNITS if Path(p).exists()]
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
    dest.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="boji-backup-", dir=root))
    plain = work / "recovery.tar.gz"
    output = dest / ("bojiclub-full-" + stamp + ".boji")
    members: list[dict] = []
    try:
        database = os.environ.get("BOJI_MYSQL_DATABASE", "bojiclub")
        dump_path = work / "database.sql"
        dump_command = ["mysqldump"]
        if os.environ.get("BOJI_MYSQL_SOCKET"):
            dump_command.append("--socket=" + os.environ["BOJI_MYSQL_SOCKET"])
        dump_command += ["--single-transaction", "--routines", "--triggers", database]
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
        with tarfile.open(plain, "w:gz") as tar:
            tar.add(str(dump_path), arcname="database.sql")
            if (work / "ai-jobs.sqlite3").exists():
                tar.add(str(work / "ai-jobs.sqlite3"), arcname="ai-jobs.sqlite3")
            for path in paths + optional:
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
        salt = os.urandom(16); nonce = os.urandom(12)
        key = Scrypt(salt=salt, length=32, n=32768, r=8, p=1).derive(password.encode())
        encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
        with plain.open("rb") as source, output.open("wb") as target:
            target.write(b"BOJIBACKUP2" + salt + nonce)
            while chunk := source.read(1024 * 1024):
                target.write(encryptor.update(chunk))
            target.write(encryptor.finalize()); target.write(encryptor.tag)
        output.chmod(0o600)
        offsite = "pending"
        offsite_command = os.environ.get("BOJI_OFFSITE_CMD", "")
        if offsite_command:
            result = subprocess.run(["sh", "-c", offsite_command + ' "$1"', "boji-offsite", str(output)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=900)
            offsite = "ok" if result.returncode == 0 else "failed"
        result_value = {
            "path": str(output), "bytes": output.stat().st_size,
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
    args = parser.parse_args()
    return backup(args)


if __name__ == "__main__":
    raise SystemExit(main())
