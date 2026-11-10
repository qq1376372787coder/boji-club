#!/usr/bin/env python3
"""Deploy only the shared-profile/onboarding API delta; never exports user data.
Run as root on the designated server after isolated tests. The candidate directory
contains account-server/ plus build133-server-manifest.json. --check is read-only
for production; --apply adds the progress table and atomically replaces 4 files.
"""
import argparse,fcntl,hashlib,json,os,re,shutil,subprocess,time
from pathlib import Path

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(args,**kw):
 p=subprocess.run([str(a) for a in args],text=True,capture_output=True,**kw)
 if p.returncode:raise RuntimeError('Command failed: '+str(args[0])+' '+p.stdout.strip()+' '+p.stderr.strip())
 return p.stdout.strip()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('candidate',type=Path);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
 root=Path('/opt/bojiclub-account');candidate=args.candidate.resolve();manifest=json.loads((candidate/'build133-server-manifest.json').read_text())
 expected={'public/onboarding-v2.php','public/index.php','migrate-onboarding-v2.php','migrations/20261026-onboarding-v2.sql'}
 if set(manifest['files'])!=expected:raise RuntimeError('Unexpected deployment boundary')
 with open('/run/lock/bojiclub-shared-profile133.lock','w') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  for rel,meta in manifest['files'].items():
   if digest(candidate/'account-server'/rel)!=meta['after_sha256']:raise RuntimeError('Candidate hash mismatch '+rel)
   if digest(root/rel)!=meta['before_sha256']:raise RuntimeError('Live file changed since baseline: '+rel)
   if rel.endswith('.php'):run(['php','-l',candidate/'account-server'/rel])
  run(['systemctl','is-active','php-fpm'])
  # Only the database name is returned; passwords/configuration are never printed.
  code='$c=require '+json.dumps(str(root/'config.php'))+';if(!preg_match("/dbname=([A-Za-z0-9_]+)/",$c["dsn"],$m))exit(2);echo $m[1];'
  database=run(['php','-r',code])
  if not re.fullmatch(r'[A-Za-z0-9_]+',database):raise RuntimeError('Invalid database name')
  env=dict(os.environ,BOJI_MIGRATION_DSN='mysql:unix_socket=/var/lib/mysql/mysql.sock;dbname='+database+';charset=utf8mb4',BOJI_MIGRATION_USER='root',BOJI_MIGRATION_PASSWORD='')
  p=subprocess.run(['php',str(candidate/'account-server/migrate-onboarding-v2.php'),'--check'],env=env,text=True,capture_output=True)
  if p.returncode not in [0,2]:raise RuntimeError('Schema inspection failed '+p.stderr)
  schema=json.loads(p.stdout)
  if set(schema.get('missing_tables',[]))-{'user_onboarding_checkpoints'} or schema.get('missing_columns') or schema.get('structural_drift'):raise RuntimeError('Unexpected schema drift '+p.stdout)
  if not args.apply:print(json.dumps({'status':'DEPLOYMENT_READY','schema':schema}));return
  backup=Path('/root/bojiclub-deploy-backups')/(time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-shared-profile133');backup.mkdir(parents=True,mode=0o700);os.chmod(backup,0o700)
  for rel in expected:
   dest=backup/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/rel,dest)
  run(['php',candidate/'account-server/migrate-onboarding-v2.php','--apply'],env=env)
  try:
   for rel in ['migrations/20261026-onboarding-v2.sql','migrate-onboarding-v2.php','public/onboarding-v2.php','public/index.php']:
    live=root/rel;tmp=live.with_name('.build133-'+live.name);st=live.stat();shutil.copyfile(candidate/'account-server'/rel,tmp);os.chmod(tmp,st.st_mode);os.chown(tmp,st.st_uid,st.st_gid);os.replace(tmp,live)
   run(['systemctl','reload','php-fpm'])
   run(['php',root/'migrate-onboarding-v2.php','--check'],env=env)
   for rel,meta in manifest['files'].items():
    if digest(root/rel)!=meta['after_sha256']:raise RuntimeError('Live hash mismatch '+rel)
   run(['curl','--fail','--silent','--show-error','--max-time','15','https://117.50.119.49/account/v1/config'])
  except Exception:
   for rel in expected:
    live=root/rel;tmp=live.with_name('.rollback133-'+live.name);shutil.copy2(backup/rel,tmp);os.replace(tmp,live)
   subprocess.run(['systemctl','reload','php-fpm'],capture_output=True);raise
  print(json.dumps({'status':'DEPLOYED','build':133,'backup':str(backup),'schema':'SCHEMA_OK','files':{rel:digest(root/rel) for rel in sorted(expected)},'production_user_records_exported':False}))
if __name__=='__main__':main()
