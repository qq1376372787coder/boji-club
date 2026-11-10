#!/usr/bin/env python3
"""Verify or restore a Boji Club full-recovery archive (FIX-009).

This script never contacts production and never starts services. Default mode
only decrypts and verifies the manifest. `--apply --target DIR` extracts into a
new, empty directory for an isolated recovery drill; the operator then installs
units and switches traffic deliberately.

The backup password is read from a root-only file (or prompted); it is never
printed. The archive is rejected if any member path escapes the target.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import tempfile

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
except ImportError:
    Cipher = None


def fail(message: str) -> "NoReturn":
    print("RESTORE_FAILED: " + message, file=sys.stderr)
    raise SystemExit(1)


def safe_members(tar: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = tar.getmembers()
    for member in members:
        name = member.name
        if name.startswith("/") or ".." in Path(name).parts or name.startswith("\\"):
            fail("archive contains an unsafe path")
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if posixpath.isabs(member.linkname) or target == ".." or target.startswith("../"):
                fail("archive contains an unsafe symlink: " + name + " -> " + member.linkname)
        if not (member.isfile() or member.isdir() or member.issym()):
            fail("archive contains an unsupported special file")
    return members


def decrypt(archive: Path, password: str, output: Path) -> None:
    if Cipher is None:
        fail("python cryptography is required")
    header_size = 11 + 16 + 12
    archive_size = archive.stat().st_size
    if archive_size < header_size + 16:
        fail("archive is truncated")
    try:
        with archive.open("rb") as raw:
            header = raw.read(header_size)
            if len(header) != header_size or not header.startswith(b"BOJIBACKUP2"):
                fail("unsupported archive format")
            salt, nonce = header[11:27], header[27:39]
            ciphertext_size = archive_size - header_size - 16
            raw.seek(header_size + ciphertext_size)
            tag = raw.read(16)
            if len(tag) != 16:
                fail("archive is truncated")
            raw.seek(header_size)
            key = Scrypt(salt=salt, length=32, n=32768, r=8, p=1).derive(password.encode())
            decryptor = Cipher(algorithms.AES(key), modes.GCM(nonce, tag)).decryptor()
            remaining = ciphertext_size
            with output.open("wb") as target:
                while remaining:
                    chunk = raw.read(min(1024 * 1024, remaining))
                    if not chunk:
                        fail("archive is truncated")
                    remaining -= len(chunk)
                    target.write(decryptor.update(chunk))
                target.write(decryptor.finalize())
                target.flush()
                os.fsync(target.fileno())
        output.chmod(0o600)
    except Exception:
        output.unlink(missing_ok=True)
        fail("wrong password or damaged archive")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify/restore a Boji Club recovery archive")
    parser.add_argument("archive")
    parser.add_argument("--password-file", default="/root/bojiclub-rebuild-v59/backup-password")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--target", help="new empty directory for --apply")
    args = parser.parse_args()
    archive = Path(args.archive)
    if not archive.is_file():
        fail("archive not found")
    password = os.environ.get("BOJI_BACKUP_PASSWORD", "")
    if not password:
        password_file = Path(args.password_file)
        if not password_file.is_file():
            fail("password file not found and BOJI_BACKUP_PASSWORD is empty")
        password = password_file.read_text().strip()
    if len(password) < 24:
        fail("backup password is too short")
    work = Path(tempfile.mkdtemp(prefix="boji-restore-"))
    plain = work / "recovery.tar.gz"
    try:
        decrypt(archive, password, plain)
        with tarfile.open(plain, "r:gz") as tar:
            members = safe_members(tar)
            manifest_member = next((m for m in members if m.name == "recovery-manifest.json"), None)
            if manifest_member is None:
                fail("recovery-manifest.json is missing")
            manifest = json.loads(tar.extractfile(manifest_member).read().decode())
            if manifest.get("version") != 2:
                fail("unsupported manifest version")
            fingerprint = hashlib.sha256(password.encode()).hexdigest()[:16]
            if manifest.get("key_fingerprint") != fingerprint:
                fail("archive key fingerprint does not match")
            required = {"database.sql", "recovery-manifest.json"}
            names = {m.name for m in members}
            if not required.issubset(names):
                fail("database.sql is missing")
            print("VERIFY_OK members=" + str(len(members)) + " created=" + str(manifest.get("created_at")))
            if "ai-jobs.sqlite3" in names:
                print("VERIFY_AI_SQLITE present")
            for item in manifest.get("includes", []):
                if item.get("kind") == "file" and item.get("path", "").startswith("/etc/bojiclub/"):
                    print("VERIFY_APPLE_KEY_ENTRY present")
                    break
        if not args.apply:
            return 0
        target = Path(args.target or "")
        if not str(target) or target.exists() and any(target.iterdir()):
            fail("--target must be a new empty directory")
        target.mkdir(parents=True, exist_ok=True)
        with tarfile.open(plain, "r:gz") as tar:
            safe_members(tar)
            tar.extractall(target)
        print("RESTORE_EXTRACTED " + str(target))
        print("NEXT: install systemd units, restore MySQL/SQLite, verify, then switch traffic manually.")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
