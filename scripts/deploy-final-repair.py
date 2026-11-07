#!/usr/bin/env python3
"""Root-only staged deployment for the existing Rocky BOJI host.

Usage: python3 deploy-final-repair.py /var/tmp/boji-fix-20261025 --plan|--apply
Uses existing server credentials in place. No credentials or user data are
returned to the caller. Backups stay under /root with mode 0700.
"""
import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

RELEASE = '20261026-build121'
ACCOUNT = Path('/opt/bojiclub-account')
AI = Path('/opt/bojiclub-ai')
NGINX = Path('/etc/nginx/conf.d/bojiclub-ip.conf')
POOL = Path('/etc/php-fpm.d/bojiclub-stream.conf')
WORKERS = ['action-jobs', 'ai-runs', 'ai-run-prune', 'domain-outbox', 'domain-notifications', 'domain-reconcile']


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def selected(stage):
    candidate = stage / 'candidate'
    pairs = []
    for path in (candidate / 'account-server').rglob('*'):
        rel = path.relative_to(candidate / 'account-server')
        if not path.is_file() or path.is_symlink() or any(p.startswith('.') for p in rel.parts):
            continue
        if len(rel.parts) == 1:
            if path.name == 'config.php' or path.suffix not in ('.php', '.sql'):
                continue
        elif rel.parts[0] not in ('public', 'admin', 'resources', 'migrations'):
            continue
        pairs.append((path, ACCOUNT / rel))
    for path in (candidate / 'backend').iterdir():
        if path.is_file() and not path.is_symlink() and not path.name.startswith('.') and path.suffix in ('.py', '.json', '.sql'):
            pairs.append((path, AI / path.name))
    return pairs


def migrate(stage, check=False):
    env = os.environ.copy()
    env.update(BOJI_MIGRATION_ROOT='1', BOJI_MYSQL_SOCKET='/var/lib/mysql/mysql.sock')
    env['BOJI_MIGRATION_DSN']='mysql:unix_socket=/var/lib/mysql/mysql.sock;dbname=bojiclub;charset=utf8mb4'
    env['BOJI_MIGRATION_USER']='root'
    env['BOJI_MIGRATION_PASSWORD']=''
    for name in ('migrate-build112-compat', 'migrate-v2-quality', 'migrate-v2-repair', 'migrate-onboarding-v2'):
        with (stage / (name + ('.check.log' if check else '.apply.log'))).open('w') as log:
            run(['php', (stage / 'candidate/account-server' if name == 'migrate-onboarding-v2' else stage / 'migration-code') / (name + '.php'), '--check' if check else '--apply'],
                env=env, stdout=log, stderr=subprocess.STDOUT)


def atomic_copy(source, dest, mode=0o644):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name('.' + dest.name + '.boji-release')
    shutil.copyfile(source, tmp)
    os.chmod(tmp, mode)
    os.replace(tmp, dest)


def active(unit):
    return subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0


def deploy(stage, apply=False):
    if os.geteuid() != 0:
        raise SystemExit('Must run as root on the designated host')
    if not ACCOUNT.joinpath('config.php').is_file() or not AI.joinpath('.env').is_file():
        raise SystemExit('Existing service configuration is required')
    files = selected(stage)
    baseline = [{'source': str(a), 'destination': str(b), 'before': digest(b), 'after': digest(a)} for a, b in files]
    report = {'release': RELEASE, 'files': len(files), 'changed': sum(v['before'] != v['after'] for v in baseline)}
    (stage / 'deployment-plan.json').write_text(json.dumps({'summary': report, 'files': baseline}, indent=2))
    # Validate the complete candidate configuration before stopping any service.
    content = NGINX.read_text()
    content = re.sub(r'\n# BOJI_SSE_BEGIN.*?# BOJI_SSE_END\n', '\n', content, flags=re.S)
    content = content.replace('location ^~ /account/v1/', 'location /account/v1/')
    if 'location /account/v1/' not in content: raise RuntimeError('Unrecognized account route')
    pos = content.index('location /account/v1/')
    content = content[:pos] + '\n# BOJI_SSE_BEGIN\n' + (stage/'candidate/account-server/deploy/bojiclub-stream-location.conf').read_text() + '\n# BOJI_SSE_END\n' + content[pos:]
    content = content.replace('include fastcgi_params;', 'include /etc/nginx/fastcgi_params;')
    candidate_site = stage/'nginx-candidate-site.conf'
    candidate_site.write_text(content)
    root_nginx = Path('/etc/nginx/nginx.conf').read_text()
    includes = '\n'.join('include ' + str(p) + ';' for p in sorted(Path('/etc/nginx/conf.d').glob('*.conf')) if p != NGINX)
    includes += '\ninclude ' + str(candidate_site) + ';'
    root_nginx, count = re.subn(r'include\s+/etc/nginx/conf.d/\*\.conf\s*;', lambda _: includes, root_nginx)
    if count != 1: raise RuntimeError('Unrecognized nginx include topology')
    candidate_nginx = stage/'nginx-candidate.conf'
    candidate_nginx.write_text(root_nginx)
    # Nginx resolves relative includes against -c's directory, including files
    # nested under the existing default.d tree. Mirror only standard includes.
    for name in ('fastcgi_params','fastcgi.conf','mime.types','scgi_params','uwsgi_params'):
        link = stage/name
        if not link.exists() and Path('/etc/nginx',name).exists():
            link.symlink_to(Path('/etc/nginx',name))
    run(['nginx','-t','-c',candidate_nginx])
    pool_candidate = stage/'php-fpm-stream-candidate.conf'
    pool_candidate.write_text((stage/'candidate/account-server/deploy/bojiclub-stream-pool.conf').read_text())
    root_fpm = Path('/etc/php-fpm.conf').read_text()
    pool_includes = '\n'.join('include=' + str(p) for p in sorted(Path('/etc/php-fpm.d').glob('*.conf')) if p != POOL)
    pool_includes += '\ninclude=' + str(pool_candidate)
    root_fpm, count = re.subn(r'include\s*=\s*/etc/php-fpm.d/\*\.conf', lambda _: pool_includes, root_fpm)
    if count != 1: raise RuntimeError('Unrecognized php-fpm include topology')
    candidate_fpm = stage/'php-fpm-candidate.conf'; candidate_fpm.write_text(root_fpm)
    run(['php-fpm','-t','-y',candidate_fpm])
    if not apply:
        print(json.dumps(report)); return
    lock = open('/run/lock/boji-release-deploy.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    backup = Path('/root/bojiclub-deploy-backups') / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-build121')
    backup.mkdir(mode=0o700, parents=True)
    os.chmod(backup, 0o700)
    old = backup / 'files'
    old.mkdir(mode=0o700)
    controls = [NGINX, POOL]
    for worker in WORKERS:
        controls += [Path('/etc/systemd/system') / ('bojiclub-' + worker + '.' + suffix) for suffix in ('service','timer')]
    # Include release metadata so rollback restores the previous provenance too.
    metadata_path = ACCOUNT / ('RELEASE-' + RELEASE + '.json')
    controls.append(metadata_path)
    existing = {}
    for dest in [b for _, b in files] + controls:
        existing[str(dest)] = dest.is_file()
        if dest.is_file():
            target = old / str(dest).lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(dest, target)
    for name, path in [('account-config.php', ACCOUNT/'config.php'), ('ai.env', AI/'.env')]:
        shutil.copy2(path, backup/name); os.chmod(backup/name, 0o600)
    with (backup/'database.sql').open('wb') as dump:
        run(['mariadb-dump','--no-defaults','--socket=/var/lib/mysql/mysql.sock','-uroot',
             '--single-transaction','--quick','--routines','--events','--hex-blob','bojiclub'], stdout=dump)
    os.chmod(backup/'database.sql', 0o600)
    source_db = sqlite3.connect('file:' + str(AI/'.data/jobs.sqlite3') + '?mode=ro', uri=True)
    with sqlite3.connect(backup/'ai-jobs.sqlite3') as target_db:
        source_db.backup(target_db)
    source_db.close(); os.chmod(backup/'ai-jobs.sqlite3', 0o600)
    (backup/'manifest.json').write_text(json.dumps({'files': baseline, 'existing': existing}, indent=2))
    timers = ['bojiclub-outbox.timer'] + ['bojiclub-' + w + '.timer' for w in WORKERS]
    previously_active = [t for t in timers if active(t)]
    previous_enabled = [t for t in timers if subprocess.run(['systemctl','is-enabled','--quiet',t],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0]
    (backup/'timers.json').write_text(json.dumps({'active':previously_active,'enabled':previous_enabled}))
    def restore():
        for worker in WORKERS:
            subprocess.run(['systemctl','disable','--now','bojiclub-'+worker+'.timer'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['systemctl','stop','php-fpm','bojiclub-ai'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for name, had_file in existing.items():
            dest = Path(name)
            if had_file: atomic_copy(old/name.lstrip('/'), dest)
            elif dest.is_file(): dest.unlink()
        subprocess.run(['systemctl','daemon-reload'])
        subprocess.run(['nginx','-t'])
        subprocess.run(['systemctl','restart','php-fpm','bojiclub-ai'])
        subprocess.run(['systemctl','reload','nginx'])
        for timer in previous_enabled: subprocess.run(['systemctl','enable',timer],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for timer in previously_active: subprocess.run(['systemctl','start',timer])
        (stage/'deployment-result.json').write_text(json.dumps({'status':'ROLLED_BACK','backup':str(backup),'database':'additive migrations retained; no destructive data restore'},indent=2))
    mutated = False
    try:
        for row in baseline:
            if digest(Path(row['destination'])) != row['before']:
                raise RuntimeError('Live code changed since preflight; refuse overwrite')
        mutated = True
        for timer in previously_active: run(['systemctl','stop',timer])
        # Stop current worker services as well before installing dependent code.
        for name in ['bojiclub-outbox'] + ['bojiclub-'+w for w in WORKERS]:
            subprocess.run(['systemctl','stop',name+'.service'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        migrate(stage)
        migrate(stage, check=True)
        run(['systemctl','stop','php-fpm','bojiclub-ai'])
        for source, dest in files: atomic_copy(source, dest)
        stream = stage/'candidate/account-server/deploy/bojiclub-stream-location.conf'
        content = NGINX.read_text()
        content = re.sub(r'\n# BOJI_SSE_BEGIN.*?# BOJI_SSE_END\n', '\n', content, flags=re.S)
        if 'location ^~ /account/v1/' not in content and 'location /account/v1/' not in content:
            raise RuntimeError('Unrecognized account route')
        content = content.replace('location ^~ /account/v1/', 'location /account/v1/')
        pos = content.index('location /account/v1/')
        content = content[:pos] + '\n# BOJI_SSE_BEGIN\n' + stream.read_text() + '\n# BOJI_SSE_END\n' + content[pos:]
        NGINX.write_text(content)
        atomic_copy(stage/'candidate/account-server/deploy/bojiclub-stream-pool.conf', POOL)
        for worker in WORKERS:
            for suffix in ('service','timer'):
                source = stage/'candidate/account-server/deploy'/('bojiclub-'+worker+'.'+suffix)
                dest = Path('/etc/systemd/system')/source.name
                text = source.read_text().replace('User=www-data','User=nginx').replace('Group=www-data','Group=nginx')
                dest.write_text(text); os.chmod(dest,0o644)
        run(['php-fpm','-t'], stdout=subprocess.DEVNULL)
        run(['nginx','-t'])
        run(['systemctl','daemon-reload'])
        run(['systemctl','start','php-fpm','bojiclub-ai'])
        run(['systemctl','reload','nginx'])
        for _ in range(20):
            check = subprocess.run(['curl','-fsS','--max-time','2','http://127.0.0.1:8787/health'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if check.returncode == 0: break
            time.sleep(.5)
        else: raise RuntimeError('AI health failed')
        run(['curl','-fsS','--max-time','10','https://117.50.119.49/account/v1/config'],stdout=subprocess.DEVNULL)
        subprocess.run(['systemctl','disable','--now','bojiclub-outbox.timer'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for worker in WORKERS: run(['systemctl','enable','--now','bojiclub-'+worker+'.timer'],stdout=subprocess.DEVNULL)
        manifest = {'release':RELEASE, 'deployed_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
                    'files':{str(dest):digest(dest) for _, dest in files}, 'backup':str(backup)}
        metadata_path.write_text(json.dumps(manifest,indent=2))
        result={'status':'DEPLOYED','release':RELEASE,'files':len(files),'backup':str(backup),
                'account_config_preserved':digest(ACCOUNT/'config.php')==digest(backup/'account-config.php'),
                'provider_env_preserved':digest(AI/'.env')==digest(backup/'ai.env')}
        (stage/'deployment-result.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result))
    except BaseException:
        if mutated: restore()
        raise

if __name__ == '__main__':
    os.umask(0o077)
    deploy(Path(sys.argv[1]).resolve(), '--apply' in sys.argv[2:])
