#!/usr/bin/env python3
"""Restore an explicitly selected encrypted backup in a disposable private DB.

Never connects to a preexisting socket, copies over production files, executes
archived programs, or starts archived services. MySQL/MariaDB is launched with
--no-defaults, a fresh datadir, private Unix socket and networking disabled.
Only backup identity, aggregate counts and safe stage codes reach the report.
Raw SQL, errors and extracted secrets remain inside the temporary private tree
and are removed after this process and its own children have stopped.
"""
from __future__ import annotations
import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

NAME = re.compile(r'bojiclub-full-[0-9]{8}T[0-9]{6}Z(?:-[0-9a-f]{8})?\.boji\Z')
_OWNED = []
_UNITS = []
DEFAULT_OUTPUT = Path('/opt/bojiclub-account/runtime/restore-drill-status.json')


class DrillError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def private_parent(path):
    if not path.is_absolute() or path.resolve() != path.absolute():
        raise DrillError('unsafe_work_directory')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise DrillError('unsafe_work_directory')


def input_file(path, key=False):
    if not path.is_absolute() or path.resolve() != path.absolute():
        raise DrillError('invalid_input')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise DrillError('invalid_input')
    if key and not 24 <= info.st_size <= 4096:
        raise DrillError('invalid_input')
    if not key and (not NAME.fullmatch(path.name) or info.st_size <= 55):
        raise DrillError('invalid_input')
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024*1024): digest.update(chunk)
    return digest.hexdigest()


def stop_owned(process):
    if process is None or process.poll() is not None:
        return True
    # Every subprocess here starts its own session. Never read a PID from an
    # archive/log/pid file and never signal an existing database process.
    try:
        if os.getpgid(process.pid) != process.pid:
            return False
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        return process.poll() is not None
    except ProcessLookupError:
        process.wait(timeout=5)
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def systemd_guard(command, work):
    runner, controller = shutil.which('systemd-run'), shutil.which('systemctl')
    if not runner or not controller or not Path('/run/systemd/system').is_dir():
        return None
    if not re.fullmatch(r'[A-Za-z0-9/._-]+', str(work)):
        raise DrillError('unsafe_work_directory')
    unit = 'boji-restore-drill-'+os.urandom(12).hex()+'.service'
    try:
        status = subprocess.run([controller, 'show', '--property=LoadState', '--value', unit], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise DrillError('filesystem_isolation_unavailable')
    if status.stdout.strip() != 'not-found':
        raise DrillError('filesystem_isolation_unavailable')
    _UNITS.append((unit, controller))
    wrapped = [runner, '--quiet', '--wait', '--pipe', '--collect', '--service-type=exec', '--unit='+unit,
               '--property=ProtectSystem=strict', '--property=ProtectHome=read-only',
               '--property=ReadWritePaths='+str(work), '--property=PrivateNetwork=yes',
               '--property=RestrictAddressFamilies=AF_UNIX', '--property=NoNewPrivileges=yes',
               '--property=MemoryMax=256M', '--property=OOMScoreAdjust=1000',
               '--property=CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETUID CAP_SETGID', '--property=PrivateDevices=yes', '--property=ProtectKernelTunables=yes',
               '--property=UMask=0077', '--property=WorkingDirectory='+str(work)]
    for key, value in {'HOME': str(work/'home'), 'MYSQL_HOME': str(work/'home'),
                       'MYSQL_TEST_LOGIN_FILE': str(work/'home'/'no-login.cnf'),
                       'TMPDIR': str(work/'tmp'), 'LC_ALL': 'C', 'LANG': 'C'}.items():
        wrapped.append('--setenv='+key+'='+value)
    return [*wrapped, '--', *command], None


def stop_units():
    safe = True
    for unit, controller in reversed(_UNITS):
        if not re.fullmatch(r'boji-restore-drill-[a-f0-9]{24}\.service', unit):
            safe = False
            continue
        try:
            subprocess.run([controller, 'stop', unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            result = subprocess.run([controller, 'show', '--property=LoadState,ActiveState', unit], capture_output=True, text=True, timeout=10)
            values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
            if values.get('LoadState') != 'not-found' and values.get('ActiveState') not in ('inactive', 'failed'):
                safe = False
        except (OSError, subprocess.SubprocessError):
            safe = False
    return safe


def write_guard(command, work):
    """Constrain even root-owned database SQL/log writes to this private tree."""
    if sys.platform == 'darwin':
        guard = Path('/usr/bin/sandbox-exec')
        if not guard.is_file(): raise DrillError('filesystem_isolation_unavailable')
        profile = '(version 1)(allow default)(deny file-write*)(allow file-write* (subpath '+json.dumps(str(work))+'))'
        return [str(guard), '-p', profile, *command], None
    if sys.platform == 'linux':
        wrapped = systemd_guard(command, work)
        if wrapped is not None: return wrapped
    if sys.platform != 'linux' or os.uname().machine not in ('x86_64', 'aarch64'):
        raise DrillError('filesystem_isolation_unavailable')
    libc = ctypes.CDLL(None, use_errno=True)
    # Landlock syscall numbers are shared by Linux x86-64 and AArch64.
    abi = libc.syscall(444, 0, 0, 1)
    if abi < 1: raise DrillError('filesystem_isolation_unavailable')
    handled = (1 << 1) | sum(1 << bit for bit in range(4, 13))
    if abi >= 2: handled |= 1 << 13  # REFER: cross-directory links/renames.
    if abi >= 3: handled |= 1 << 14  # TRUNCATE.
    class Ruleset(ctypes.Structure):
        _fields_ = [('handled_access_fs', ctypes.c_uint64)]
    class PathBeneath(ctypes.Structure):
        _pack_ = 1
        _fields_ = [('allowed_access', ctypes.c_uint64), ('parent_fd', ctypes.c_int)]
    def restrict():
        rule, descriptor, parent_fd = Ruleset(handled), -1, -1
        try:
            descriptor = libc.syscall(444, ctypes.byref(rule), ctypes.sizeof(rule), 0)
            if descriptor < 0: raise OSError('sandbox unavailable')
            parent_fd = os.open(work, os.O_PATH | os.O_CLOEXEC)
            path_rule = PathBeneath(handled, parent_fd)
            if libc.syscall(445, descriptor, 1, ctypes.byref(path_rule), 0) != 0:
                raise OSError('sandbox rule rejected')
            if libc.prctl(38, 1, 0, 0, 0) != 0 or libc.syscall(446, descriptor, 0) != 0:
                raise OSError('sandbox enforcement failed')
        finally:
            if parent_fd >= 0: os.close(parent_fd)
            if descriptor >= 0: os.close(descriptor)
    return command, restrict


def run_private(command, env, work, code, timeout=120, stdin=None, capture=False, sandbox=False):
    # Only short metadata queries/version probes are captured in memory.
    command, guard = write_guard(command, work) if sandbox else (command, None)
    log_path = work/'private-command.log'
    with log_path.open('ab') as log:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen(command, cwd=work, env=env, stdin=stdin or subprocess.DEVNULL,
                                   stdout=subprocess.PIPE if capture else log, stderr=log, start_new_session=True, preexec_fn=guard)
        _OWNED.append(process)
        try:
            output, _ = process.communicate(timeout=timeout)
            if process.returncode:
                raise DrillError(code)
            return output or b''
        except BaseException:
            if not stop_owned(process):
                raise DrillError('cleanup_failed')
            raise


def executable(candidates):
    for candidate in candidates:
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    raise DrillError('dependency_missing')


def binaries(basedir):
    if basedir is None:
        found = shutil.which('mariadbd') or shutil.which('mysqld')
        if not found: raise DrillError('dependency_missing')
        daemon = Path(found).resolve()
        basedir = daemon.parent.parent
    else:
        basedir = basedir.resolve()
        daemon = executable([basedir/'bin/mariadbd', basedir/'sbin/mariadbd', basedir/'bin/mysqld', basedir/'sbin/mysqld'])
    client = executable([basedir/'bin/mariadb', basedir/'bin/mysql'])
    return basedir, daemon, client


def db_client(client, socket, work, maria):
    # A generated socket under this exact fresh directory is the only target.
    if socket.parent != work or socket.name != 'mysql.sock' or work.resolve() != work:
        raise DrillError('unsafe_socket')
    return [str(client), '--no-defaults', *([] if maria else ['--no-login-paths']),
            '--protocol=SOCKET', '--socket='+str(socket), '--host=localhost', '--user=root', '--password=',
            '--connect-timeout=2', '--batch', '--skip-column-names', '--raw', '--binary-mode',
            '--local-infile=0', '--skip-reconnect']


def count_tables(client, database, env, work):
    names = run_private(client+['-e', "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+database+"' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME"],
                        env, work, 'mysql_verify_failed', capture=True).decode('utf-8').splitlines()
    if not names or len(names) > 2000 or any(not re.fullmatch(r'[A-Za-z0-9_]+', name) for name in names):
        raise DrillError('mysql_verify_failed')
    query = ' '.join('SELECT COUNT(*) FROM `'+database+'`.`'+name+'`;' for name in names)
    values = run_private(client+['-e', query], env, work, 'mysql_verify_failed', capture=True).decode('ascii').splitlines()
    if len(values) != len(names) or any(not re.fullmatch(r'[0-9]+', value) for value in values):
        raise DrillError('mysql_verify_failed')
    return {'table_count': len(names), 'record_count': sum(map(int, values))}


def sqlite_check(path, extracted):
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(extracted):
        raise DrillError('ai_database_failed')
    try:
        with sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=5) as database:
            database.execute('PRAGMA trusted_schema=OFF')
            result = database.execute('PRAGMA quick_check').fetchmany(2)
        if result != [('ok',)]: raise DrillError('ai_database_failed')
        return 'passed'
    except (OSError, sqlite3.Error):
        raise DrillError('ai_database_failed')


def clean_work(work, parent):
    if work.parent != parent or not work.name.startswith('restore-drill-') or work.resolve() != work:
        return False
    try:
        info = work.lstat()
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
            return False
        shutil.rmtree(work)
        return not work.exists()
    except OSError:
        return False


def drill(args):
    global _OWNED, _UNITS
    _OWNED, _UNITS = [], []
    result = {'schema_version': 1, 'kind': 'restore_drill', 'checked_at': stamp(), 'status': 'failed',
              'archive': args.archive.name if NAME.fullmatch(args.archive.name) else None,
              'sha256': None, 'mysql': {'state': 'not_verified'}, 'ai_sqlite': {'state': 'not_verified'},
              'error_code': None, 'production_connected': False, 'isolation': {'state': 'not_verified'}, 'cleanup_complete': False}
    work, daemon_process = None, None
    try:
        initial_archive = input_file(args.archive)
        initial_key = input_file(args.password_file, key=True)
        result['sha256'] = digest_file(args.archive)
        private_parent(args.work_parent)
        work = Path(tempfile.mkdtemp(prefix='restore-drill-', dir=args.work_parent)).resolve()
        for name in ('home', 'tmp', 'sqlfiles', 'restore-temp'):
            (work/name).mkdir(mode=0o700)
        socket = work/'mysql.sock'
        if len(os.fsencode(socket)) > 100:
            raise DrillError('unsafe_socket')
        env = {'PATH': os.defpath, 'HOME': str(work/'home'), 'MYSQL_HOME': str(work/'home'),
               'MYSQL_TEST_LOGIN_FILE': str(work/'home'/'no-login.cnf'),
               'TMPDIR': str(work/'tmp'), 'LC_ALL': 'C', 'LANG': 'C'}
        basedir, daemon, client_path = binaries(args.mysql_basedir)
        version = run_private([str(daemon), '--no-defaults', '--version'], env, work, 'dependency_missing', capture=True).decode('utf-8', errors='replace')
        maria = 'mariadb' in version.lower()
        version_match = re.search(r'(?:Ver\s+|Distrib\s+)([0-9]+\.[0-9]+(?:\.[0-9]+)?)', version)
        result['mysql']['engine'] = 'MariaDB' if maria else 'MySQL'
        if version_match: result['mysql']['version'] = version_match.group(1)
        extracted = work/'extracted'
        # restore.py is used only for authenticated decryption, validation and
        # extraction. Its printed NEXT instructions are never acted upon.
        extract_env = {**os.environ, 'TMPDIR': str(work/'restore-temp')}
        extract_env.pop('BOJI_BACKUP_PASSWORD', None)  # Explicit key input always wins.
        run_private([sys.executable, str(Path(__file__).with_name('restore.py')), str(args.archive),
                     '--password-file', str(args.password_file), '--apply', '--target', str(extracted)],
                    extract_env, work, 'decrypt_or_extract_failed', timeout=args.timeout)
        if input_file(args.archive) != initial_archive or input_file(args.password_file, key=True) != initial_key:
            raise DrillError('input_changed')
        sql = extracted/'database.sql'
        if sql.is_symlink() or not sql.is_file() or not sql.resolve().is_relative_to(extracted):
            raise DrillError('mysql_import_failed')
        result['ai_sqlite']['state'] = sqlite_check(extracted/'ai-jobs.sqlite3', extracted)
        datadir = work/'mysql-data'
        datadir.mkdir(mode=0o700)
        user = pwd.getpwuid(os.getuid()).pw_name
        if maria:
            installer = executable([basedir/'bin/mariadb-install-db', basedir/'scripts/mariadb-install-db',
                                    basedir/'bin/mysql_install_db', basedir/'scripts/mysql_install_db'])
            initialize = [str(installer), '--no-defaults', '--basedir='+str(basedir), '--datadir='+str(datadir),
                          '--auth-root-authentication-method=normal', '--skip-test-db', '--user='+user,
                          '--innodb-buffer-pool-size=64M', '--skip-networking', '--event-scheduler=OFF', '--local-infile=0']
        else:
            initialize = [str(daemon), '--no-defaults', '--basedir='+str(basedir), '--datadir='+str(datadir),
                          '--initialize-insecure', '--user='+user, '--innodb-buffer-pool-size=64M',
                          '--performance-schema=OFF', '--skip-networking', '--mysqlx=OFF']
        run_private(initialize, env, work, 'mysql_initialize_failed', timeout=args.timeout, sandbox=True)
        command = [str(daemon), '--no-defaults', '--basedir='+str(basedir), '--datadir='+str(datadir),
                   '--user='+user, '--socket='+str(socket), '--pid-file='+str(work/'mysql.pid'),
                   '--log-error='+str(work/'mysql-private.log'), '--skip-networking', '--port=0',
                   '--skip-log-bin', '--event-scheduler=OFF', '--local-infile=0', '--skip-name-resolve',
                   '--secure-file-priv='+str(work/'sqlfiles'), '--innodb-buffer-pool-size=64M',
                   '--innodb-log-buffer-size=8M', '--max-connections=5', '--performance-schema=OFF']
        if not maria: command.append('--mysqlx=OFF')
        command, guard = write_guard(command, work)
        with (work/'daemon-private.log').open('ab') as log:
            os.chmod(work/'daemon-private.log', 0o600)
            daemon_process = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
                                              stdout=log, stderr=log, start_new_session=True, preexec_fn=guard)
        _OWNED.append(daemon_process)
        client = db_client(client_path, socket, work, maria)
        deadline = time.monotonic()+min(args.timeout, 120)
        while True:
            if daemon_process.poll() is not None: raise DrillError('mysql_start_failed')
            if socket.exists():
                try:
                    answer = run_private(client+['-e', 'SELECT 1'], env, work, 'mysql_start_failed', timeout=5, capture=True)
                    if answer.strip() == b'1': break
                except DrillError as error:
                    if error.code == 'cleanup_failed': raise
            if time.monotonic() >= deadline: raise DrillError('mysql_start_failed')
            time.sleep(.2)
        isolation = run_private(client+['-e', 'SELECT @@datadir,@@socket,@@skip_networking,@@secure_file_priv,@@event_scheduler,@@local_infile'], env, work, 'isolation_failed', capture=True).decode('utf-8').strip().split('\t')
        if len(isolation) != 6 or Path(isolation[0]).resolve() != datadir or Path(isolation[1]).resolve() != socket or isolation[2] != '1' or Path(isolation[3]).resolve() != work/'sqlfiles' or isolation[4].upper() != 'OFF' or isolation[5] != '0':
            raise DrillError('isolation_failed')
        result['isolation'] = {'state': 'passed', 'fresh_datadir': True, 'private_socket': True, 'skip_networking': True, 'no_defaults': True, 'filesystem_write_restricted': True, 'local_infile_disabled': True, 'events_disabled': True}
        run_private(client+['-e', 'CREATE DATABASE `'+args.database+'` CHARACTER SET utf8mb4'], env, work, 'mysql_import_failed')
        with sql.open('rb') as source:
            run_private(client+['--database='+args.database], env, work, 'mysql_import_failed', timeout=args.timeout, stdin=source)
        result['mysql'].update(state='passed', **count_tables(client, args.database, env, work))
        result['status'] = 'passed'
    except DrillError as error:
        result['error_code'] = error.code
    except (OSError, ValueError, TypeError, UnicodeError, subprocess.SubprocessError):
        result['error_code'] = 'drill_failed'
    finally:
        units_stopped = stop_units()
        children_stopped = all([stop_owned(process) for process in reversed(_OWNED)])
        stopped = units_stopped and children_stopped
        cleaned = stopped and (work is None or clean_work(work, args.work_parent))
        result['cleanup_complete'] = bool(cleaned)
        if not cleaned:
            result['status'], result['error_code'] = 'failed', 'cleanup_failed'
        result['checked_at'] = stamp()
    return result


def write_result(path, result):
    # A report path cannot be repurposed to overwrite a config/database/archive.
    if path.name != 'restore-drill-status.json' or not path.is_absolute() or path.is_symlink() or path.resolve() != path.absolute():
        raise DrillError('unsafe_report_path')
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if path.exists():
        existing = json.loads(path.read_text())
        if not isinstance(existing, dict) or existing.get('kind') != 'restore_drill':
            raise DrillError('unsafe_report_path')
    fd, temporary = tempfile.mkstemp(prefix='.restore-drill-status-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), 0o644)
            json.dump(result, output)
            output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def interrupted(signum, frame):
    signal.signal(signum, signal.SIG_IGN)
    raise DrillError('interrupted')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--password-file', required=True, type=Path)
    parser.add_argument('--mysql-basedir', type=Path)
    parser.add_argument('--database', default='bojiclub')
    parser.add_argument('--work-parent', type=Path, default=Path('/var/lib/bojiclub-restore-drill'))
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_]{1,64}', args.database) or args.database.lower() in ('mysql', 'information_schema', 'performance_schema', 'sys') or not 5 <= args.timeout <= 3600:
        result = {'schema_version': 1, 'kind': 'restore_drill', 'status': 'failed', 'error_code': 'invalid_options', 'checked_at': stamp(),
                  'archive': args.archive.name if NAME.fullmatch(args.archive.name) else None, 'sha256': None,
                  'mysql': {'state': 'not_verified'}, 'ai_sqlite': {'state': 'not_verified'}, 'isolation': {'state': 'not_verified'},
                  'production_connected': False, 'cleanup_complete': True}
    else:
        previous = {kind: signal.signal(kind, interrupted) for kind in (signal.SIGTERM, signal.SIGINT)}
        try:
            result = drill(args)
        finally:
            for kind, handler in previous.items(): signal.signal(kind, handler)
    try:
        write_result(args.output, result)
    except (DrillError, OSError, ValueError, TypeError):
        print('RESTORE_DRILL_FAILED: safe result could not be published', file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
