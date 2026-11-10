"""Fourth repair HTTP acceptance; MUST run against isolated synthetic test DB."""
import copy,datetime as dt,hashlib,json,os,subprocess,threading,unittest,urllib.error,urllib.request
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
DB='bojiclub_repair_v4_test_20261002';BASE='http://127.0.0.1:20082/account/v1';ROOT=Path(__file__).resolve().parents[1]
USER=900060;TOKEN='v4-synthetic-session-'+'f'*40;OTHER='v4-other-session-'+'g'*40;TODAY=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date().isoformat()
MEDIA='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0060.jpg';MEAL='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0060';CLIENT='cccccccc-cccc-cccc-cccc-cccccccc0060';SERVER='dddddddd-dddd-dddd-dddd-dddddddd0060'
def sql(text):return subprocess.check_output(['mysql','-N',DB,'-e',text],text=True).strip()
def api(path,method='GET',body=None,token=TOKEN):
 req=urllib.request.Request(BASE+path,method=method,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
 try:r=urllib.request.urlopen(req,timeout=10)
 except urllib.error.HTTPError as e:r=e
 raw=r.read();return r.status,json.loads(raw)
class Worker(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  items=[{'id':value,'kind':'report','date':TODAY,'status':'queued','created':1000} for value in body['ids']]
  items.append({'id':'eeeeeeee-eeee-eeee-eeee-eeeeeeee0060','kind':'food','date':TODAY,'status':'queued','created':1000})
  self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'items':items}).encode())
 def do_DELETE(self):self.send_response(200);self.end_headers();self.wfile.write(b'{"deleted":true}')
class Acceptance(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  assert DB=='bojiclub_repair_v4_test_20261002'
  sql("DELETE FROM account_deletions WHERE user_id BETWEEN 900060 AND 900069;DELETE FROM users WHERE id BETWEEN 900060 AND 900069;DELETE FROM club_rewards WHERE season_id=900060;DELETE FROM club_tasks WHERE season_id=900060;DELETE FROM club_seasons WHERE id=900060;")
  for user,token in [(USER,TOKEN),(USER+1,OTHER)]:
   sql(f"INSERT INTO users(id,status,created_at,updated_at) VALUES({user},'active',UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES({user},'{hashlib.sha256(token.encode()).hexdigest()}',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY));")
  cls.state={'version':1,'days':{},'profile':{'nickname':'Fixture','age':28,'height':175,'weight':68,'daysPerWeek':3,'goal':'增肌','experience':'新手','venue':'在家','focus':'全身','trainingDays':[1,3,5]},'drafts':[],'importedPlan':''}
  cls.worker=ThreadingHTTPServer(('127.0.0.1',20087),Worker);threading.Thread(target=cls.worker.serve_forever,daemon=True).start()
 @classmethod
 def tearDownClass(cls):cls.worker.shutdown();cls.worker.server_close()
 def upload(self,state):
  _,env=api('/me/state');return api('/me/state','PUT',{'base_revision':env['revision'],'state':state})
 def test_01_unchanged_revision_omits_whole_snapshot(self):
  self.assertEqual(self.upload(self.state)[0],200)
  _,full=api('/me/state');status,short=api('/me/state?known_revision='+str(full['revision']))
  self.assertEqual(status,200);self.assertTrue(short['unchanged']);self.assertIsNone(short['state']);self.assertLess(len(json.dumps(short)),160)
  _,old=api('/me/state?known_revision='+str(full['revision']-1));self.assertIsInstance(old['state'],dict)
 def test_02_timed_contract_and_archived_job_tombstones_round_trip(self):
  state=copy.deepcopy(self.state);state['deletedAIJobIDs']=[CLIENT]
  state['days'][TODAY]={'meals':[],'exercises':[{'id':MEAL,'name':'平板支撑','muscle':'核心','sets':[{'id':CLIENT,'weight':0,'reps':0,'durationSeconds':45,'completed':True}]}]}
  self.assertEqual(self.upload(state)[0],200);_,read=api('/me/state');self.assertEqual(read['state']['days'][TODAY]['exercises'][0]['sets'][0]['durationSeconds'],45)
 def test_03_photo_cleanup_retries_after_committed_state_and_unchanged_get(self):
  folder=ROOT/'account-server/media'/str(USER);folder.mkdir(exist_ok=True)
  import pwd,grp
  os.chown(folder,pwd.getpwnam('www-data').pw_uid,grp.getgrnam('www-data').gr_gid)
  target=folder/MEDIA;target.write_bytes(b'\xff\xd8\xffsynthetic-only');os.chmod(folder,0o555)
  try:
   state=copy.deepcopy(self.state);state['deletedMediaIDs']=[MEDIA]
   status,value=self.upload(state);self.assertEqual(status,200);self.assertEqual(value['media_cleanup_pending'],1);self.assertTrue(target.exists())
   _,same=api('/me/state?known_revision='+str(value['revision']));self.assertTrue(same['unchanged'])
   self.assertEqual(sql(f'SELECT COUNT(*) FROM media_cleanup_queue WHERE user_id={USER}'),'1')
  finally:os.chmod(folder,0o755)
  sql(f'UPDATE media_cleanup_queue SET next_attempt=UTC_TIMESTAMP() WHERE user_id={USER}')
  subprocess.check_call(['php',str(ROOT/'account-server/process-deletions.php')])
  self.assertFalse(target.exists());self.assertEqual(sql(f'SELECT COUNT(*) FROM media_cleanup_queue WHERE user_id={USER}'),'0')
 def test_04_recovery_listing_is_account_scoped(self):
  sql(f"INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES({USER},'{CLIENT}','{SERVER}','report',UTC_TIMESTAMP())")
  status,value=api('/me/tasks');self.assertEqual(status,200);self.assertEqual([x['id'] for x in value['items']],[CLIENT]);self.assertNotIn('payload',value['items'][0])
  _,other=api('/me/tasks',token=OTHER);self.assertEqual(other['items'],[])
 def test_05_activity_does_not_count_zero_repetition_and_keeps_earned_badge(self):
  sql(f"INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES(900060,'v4-fixture','Fixture','Fixture','Fixture','{TODAY}','{TODAY}','{TODAY}','published',100,UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO club_tasks(id,season_id,title,detail,metric,target,created_at) VALUES(900060,900060,'Fixture','Fixture','training_days',1,UTC_TIMESTAMP());INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,inventory,created_at) VALUES(900060,900060,900060,'Fixture','Fixture','badge',0,UTC_TIMESTAMP());INSERT INTO club_enrollments(season_id,user_id,rules_version,joined_at) VALUES(900060,{USER},'v4-fixture',UTC_TIMESTAMP());INSERT INTO club_virtual_grants(user_id,reward_id,season_id,granted_at) VALUES({USER},900060,900060,UTC_TIMESTAMP());")
  state=copy.deepcopy(self.state);state['days'][TODAY]={'meals':[],'exercises':[{'id':MEAL,'name':'x','muscle':'x','sets':[{'id':CLIENT,'weight':0,'reps':0,'completed':True}]}]}
  self.assertEqual(self.upload(state)[0],200);_,history=api('/club/history');season=next(x for x in history['items'] if x['season']['id']==900060)
  self.assertEqual(season['tasks'][0]['current'],0);self.assertTrue(season['rewards'][0]['unlocked'])
 def test_06_beijing_quota_boundary_matches_worker(self):
  command="$path='';$method='GET';require '"+str(ROOT/'account-server/public/weekly.php')+"';echo aiUsageDayStart(1790860800);"
  # Compute expected from epoch rather than depending on current clock.
  value=subprocess.check_output(['php','-r',command],text=True).strip();expected=dt.datetime.fromtimestamp(((1790860800+28800)//86400)*86400-28800,dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%S');self.assertEqual(value,expected)
 def test_07_missing_apple_identity_cannot_recover_deletion(self):
  self.assertEqual(api('/auth/apple/deletion-status','POST',{'account_id':USER,'identity_token':'invalid','nonce':'invalid'})[0],401)

if __name__=='__main__':unittest.main(verbosity=2)
