#!/usr/bin/env python3
"""Atomically update the Build135 AI/onboarding code; never export member data."""
import argparse,fcntl,hashlib,json,os,shutil,sqlite3,subprocess,time
from pathlib import Path

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(args, **kwargs):
    r=subprocess.run([str(x) for x in args],text=True,capture_output=True,**kwargs)
    if r.returncode: raise RuntimeError('command failed: '+str(args[0])+' '+r.stderr[-500:])
    return r.stdout.strip()
def active_runs():
    code='$c=require "/opt/bojiclub-account/config.php"; $d=new PDO($c["dsn"],$c["db_user"],$c["db_password"]); $q=$d->prepare("SELECT COUNT(*) FROM ai_runs WHERE status IN (?,?)"); $q->execute(["queued","running"]); echo $q->fetchColumn();'
    return int(run(['php','-r',code]))
def active_models():
    db=sqlite3.connect('file:/opt/bojiclub-ai/.data/jobs.sqlite3?mode=ro',uri=True)
    try: return int(db.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running','retrying')").fetchone()[0])
    finally: db.close()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('candidate',type=Path);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    candidate=args.candidate.resolve(); manifest=json.loads((candidate/'build135-manifest.json').read_text())
    expected={('account-server/public/'+n, '/opt/bojiclub-account/public/'+n) for n in ['ai-entitlements.php','ai-runs.php','weekly.php','ai-memory.php','profile-facts.php']}
    expected|={('backend/'+n, '/opt/bojiclub-ai/'+n) for n in ['coach_core.py','ai_core.py','onboarding_core.py','weekly_core.py']}
    if {(v['source'],v['target']) for v in manifest['files']} != expected: raise RuntimeError('unexpected file list')
    workers=['bojiclub-ai-runs@1','bojiclub-ai-runs@2']
    with open('/run/lock/bojiclub-build135.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for item in manifest['files']:
            source=candidate/item['source'];target=Path(item['target'])
            if sha(source)!=item['after'] or sha(target)!=item['before']:raise RuntimeError('baseline changed: '+item['target'])
            if source.suffix=='.php':run(['php','-l',source])
            else:run(['python3','-m','py_compile',source])
        for unit in ['php-fpm','bojiclub-ai',*workers]:run(['systemctl','is-active','--quiet',unit])
        if active_runs() or active_models():raise RuntimeError('AI is currently processing requests; no changes made')
        if not args.apply:
            print(json.dumps({'status':'CHECK_OK','files':len(expected),'active_requests':0}));return
        backup=Path('/root/bojiclub-deploy-backups')/(time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-build135');backup.mkdir(parents=True)
        for item in manifest['files']:
            dest=backup/item['source'];dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(item['target'],dest)
        (backup/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        changed=[]
        try:
            run(['systemctl','stop',*workers])
            if active_runs() or active_models():raise RuntimeError('new AI requests arrived during deploy')
            for item in manifest['files']:
                source=candidate/item['source'];target=Path(item['target']);info=target.stat()
                tmp=target.with_name('.build135-'+target.name);shutil.copyfile(source,tmp);os.chmod(tmp,info.st_mode);os.chown(tmp,info.st_uid,info.st_gid);os.replace(tmp,target);changed.append(item)
            run(['systemctl','restart','bojiclub-ai']);run(['systemctl','reload','php-fpm']);run(['systemctl','start',*workers])
            for unit in ['php-fpm','bojiclub-ai',*workers]:run(['systemctl','is-active','--quiet',unit])
            for i in range(15):
                r=subprocess.run(['curl','-fsS','--max-time','2','http://127.0.0.1:8787/health'],capture_output=True)
                if r.returncode==0:break
                time.sleep(1)
            else:raise RuntimeError('AI health check failed')
            run(['curl','-fsS','--max-time','12','https://117.50.119.49/account/v1/config'])
            for item in manifest['files']:
                if sha(Path(item['target']))!=item['after']:raise RuntimeError('post-deploy hash mismatch')
        except Exception:
            for item in changed:
                target=Path(item['target']);tmp=target.with_name('.rollback135-'+target.name);shutil.copy2(backup/item['source'],tmp);os.replace(tmp,target)
            subprocess.run(['systemctl','restart','bojiclub-ai'],capture_output=True)
            subprocess.run(['systemctl','reload','php-fpm'],capture_output=True)
            subprocess.run(['systemctl','start',*workers],capture_output=True)
            raise
        print(json.dumps({'status':'DEPLOYED','build':135,'files':len(changed),'backup':str(backup),'health':'PASS','user_records_exported':False}))
if __name__=='__main__':main()
