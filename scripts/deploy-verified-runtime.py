#!/usr/bin/env python3
"""Deploy a hash-verified runtime delta on the designated BOJI server.

Preserves live configuration and user files. Does not execute production DDL.
Candidate manifest records each file's observed before/after hash. Existing
services/timers are resumed exactly as found; code is restored on failure.
"""
import argparse, fcntl, hashlib, json, os, shutil, sqlite3, subprocess, time
from pathlib import Path

ROOTS = {'account-server': Path('/opt/bojiclub-account'), 'backend': Path('/opt/bojiclub-ai')}
WORKERS = ['bojiclub-ai-runs@1.service', 'bojiclub-ai-runs@2.service']
TIMERS = ['bojiclub-'+name+'.timer' for name in ('scheduled-notifications','action-jobs','ai-runs','ai-run-prune','domain-outbox','domain-notifications','domain-reconcile','club-automation','club-push','account-deletions','healthcheck')]
PRIVATE = ['/opt/bojiclub-account/config.php', '/opt/bojiclub-ai/.env']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None

def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=150)
    if result.returncode: raise RuntimeError('command failed: '+str(args[0])+' '+result.stderr[-400:])
    return result.stdout.strip()

def active(unit):
    return subprocess.run(['systemctl','is-active','--quiet',unit], capture_output=True).returncode == 0

def target_for(source):
    path = Path(source)
    if path.is_absolute() or '..' in path.parts or path.parts[0] not in ROOTS: raise RuntimeError('invalid source')
    if path.name in ('config.php','.env') or any(x in path.parts for x in ('media','.data','runtime','private-cache')): raise RuntimeError('private file in candidate')
    return ROOTS[path.parts[0]].joinpath(*path.parts[1:])

def idle():
    code = """$c=require '/opt/bojiclub-account/config.php';$d=new PDO($c['dsn'],$c['db_user'],$c['db_password']);$q=$d->prepare('SELECT COUNT(*) FROM ai_runs WHERE status IN (?,?)');$q->execute(['queued','running']);echo $q->fetchColumn();"""
    if int(run(['php','-r',code])): raise RuntimeError('account AI requests are active; retry later')
    db = sqlite3.connect('file:/opt/bojiclub-ai/.data/jobs.sqlite3?mode=ro',uri=True)
    try:
        if db.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running','retrying')").fetchone()[0]: raise RuntimeError('model requests are active; retry later')
    finally: db.close()

def replace(source, target, mode=0o644, uid=0, gid=0):
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name('.boji-release-'+target.name)
    shutil.copyfile(source,temp); os.chmod(temp,mode); os.chown(temp,uid,gid)
    with temp.open('rb') as handle: os.fsync(handle.fileno())
    os.replace(temp,target)

def health():
    for _ in range(20):
        result = subprocess.run(['curl','-fsS','--max-time','2','http://127.0.0.1:8787/health'],capture_output=True)
        if result.returncode == 0: break
        time.sleep(.5)
    else: raise RuntimeError('AI health check failed')
    response = json.loads(run(['curl','-fsS','--max-time','12','https://117.50.119.49/account/v1/config']))
    if not isinstance(response.get('config'),dict): raise RuntimeError('public config response invalid')
    for unit in ['php-fpm.service','bojiclub-ai.service',*WORKERS]:
        if not active(unit): raise RuntimeError('service is inactive: '+unit)
    return response.get('version')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('candidate',type=Path);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    candidate=args.candidate.resolve(); manifest=json.loads((candidate/'manifest.json').read_text()); runtime=json.loads((candidate/'runtime-manifest.json').read_text())
    if not (candidate/'mariadb-validation.json').is_file(): raise RuntimeError('isolated MariaDB validation evidence missing')
    changes={i['source']:i for i in manifest['files']}
    with open('/run/lock/bojiclub-release.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for item in runtime['files']:
            target=target_for(item['source'])
            if str(target)!=item['target'] or target.is_symlink(): raise RuntimeError('unexpected target')
            if sha(candidate/item['source'])!=item['after']: raise RuntimeError('candidate changed: '+item['source'])
            expected=changes[item['source']]['before'] if item['source'] in changes else item['after']
            if sha(target)!=expected: raise RuntimeError('live baseline changed: '+item['source'])
        idle(); health()
        if not args.apply:
            print(json.dumps({'status':'CHECK_OK','files':len(changes),'commit':manifest['commit']}));return
        private={p:sha(Path(p)) for p in PRIVATE}
        timers=[t for t in TIMERS if active(t)]
        backup=Path('/root/bojiclub-deploy-backups')/(time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-build'+str(manifest['build'])+'-merged')
        backup.mkdir(mode=0o700,parents=True)
        metadata={}
        for item in changes.values():
            target=Path(item['target'])
            if target.exists():
                info=target.stat(); metadata[item['source']]=[info.st_mode & 0o777,info.st_uid,info.st_gid]
                dest=backup/item['source'];dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(target,dest)
        (backup/'manifest.json').write_text(json.dumps({'manifest':manifest,'metadata':metadata,'timers':timers,'private_fingerprints':private},indent=2))
        installed=[]
        print('BACKUP_READY '+str(backup),flush=True)
        try:
            if timers: run(['systemctl','stop',*timers])
            run(['systemctl','stop',*WORKERS]);idle()
            # Brief controlled API cutover prevents requests loading mixed PHP files.
            run(['systemctl','stop','php-fpm.service','bojiclub-ai.service'])
            for item in changes.values():
                replace(candidate/item['source'],Path(item['target']),*metadata.get(item['source'],[0o644,0,0]));installed.append(item)
            run(['systemctl','start','bojiclub-ai.service','php-fpm.service',*WORKERS])
            version=health()
            for item in runtime['files']:
                if sha(Path(item['target']))!=item['after']: raise RuntimeError('post-deploy hash mismatch')
            if any(sha(Path(p))!=value for p,value in private.items()): raise RuntimeError('private configuration changed')
            if timers:run(['systemctl','start',*timers])
            result={'status':'DEPLOYED','build':manifest['build'],'commit':manifest['commit'],'files':len(installed),'backup':str(backup),'config_version':version,'health':'PASS','production_ddl':False,'user_data_exported':False,'private_configuration_preserved':True}
            (backup/'result.json').write_text(json.dumps(result,indent=2));(candidate/'deployment-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
        except BaseException:
            for unit in ['php-fpm.service','bojiclub-ai.service',*WORKERS]:subprocess.run(['systemctl','stop',unit],capture_output=True)
            for item in reversed(installed):
                target=Path(item['target']); old=backup/item['source']
                if old.exists():replace(old,target,*metadata[item['source']])
                elif target.exists():target.unlink() # only files introduced by this deployment
            subprocess.run(['systemctl','start','bojiclub-ai.service','php-fpm.service',*WORKERS],capture_output=True)
            if timers:subprocess.run(['systemctl','start',*timers],capture_output=True)
            print('CODE_ROLLED_BACK '+str(backup),flush=True);raise
if __name__=='__main__':main()
