"""Repair acceptance on an isolated MySQL database and synthetic worker only."""
import base64, copy, datetime as dt, hashlib, http.cookiejar, json, re, subprocess, threading, time, unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import urllib.error,urllib.parse,urllib.request
DB='bojiclub_repair_v2_test';BASE='http://127.0.0.1:18082/account/v1';ADMIN='http://127.0.0.1:18082/admin/'
ROOT=Path(__file__).resolve().parents[1];TOKEN='v2-synthetic-session-'+'d'*40;USER=900030
TODAY=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date().isoformat();STAMP=800000000
WORKER={};DELETE_FAILURE_AT=0;DELETE_COUNT=0;REJECT_POST=False
def sql(s):return subprocess.check_output(['mysql','-N',DB,'-e',s],text=True).strip()
def api(path,method='GET',body=None,token=TOKEN,timeout=10):
 request=urllib.request.Request(BASE+path,method=method,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
 try:response=urllib.request.urlopen(request,timeout=timeout)
 except urllib.error.HTTPError as error:response=error
 data=response.read()
 try:value=json.loads(data)
 except ValueError:value={'non_json':True}
 return response.status,value
class Worker(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,status,value):
  self.send_response(status);self.end_headers();self.wfile.write(json.dumps(value).encode())
 def do_POST(self):
  value=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  if REJECT_POST:self.send(400,{'error':'invalid_request','message':'Synthetic invalid request'});return
  WORKER[value['id']]=value;self.send(202,{'id':value['id'],'status':'queued'})
 def do_GET(self):
  job=self.path.rsplit('/',1)[-1]
  self.send(200,{'id':job,'status':'queued'}) if job in WORKER else self.send(404,{'error':'not_found'})
 def do_DELETE(self):
  global DELETE_COUNT
  DELETE_COUNT+=1
  if DELETE_COUNT==DELETE_FAILURE_AT:self.send(503,{'error':'synthetic_outage'});return
  WORKER.pop(self.path.rsplit('/',1)[-1],None);self.send(200,{'deleted':True})
class Acceptance(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  sql('DELETE FROM users WHERE id=900010;DELETE FROM club_rewards WHERE season_id=900010;DELETE FROM club_tasks WHERE season_id=900010;DELETE FROM club_seasons WHERE id=900010;')
  sql("DELETE FROM account_deletions WHERE user_id BETWEEN 900030 AND 900039 OR token_hash='"+hashlib.sha256(('v2-delete-'+'e'*50).encode()).hexdigest()+"';DELETE FROM users WHERE id BETWEEN 900030 AND 900039;DELETE FROM club_seasons WHERE id BETWEEN 900030 AND 900039;DELETE FROM club_reward_catalog WHERE name LIKE 'v2-fixture%';DELETE FROM notification_templates WHERE name='v2-fixture-notice';")
  sql("INSERT INTO users(id,status,created_at,updated_at) VALUES(900030,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES(900030,'"+hashlib.sha256(TOKEN.encode()).hexdigest()+"',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY));INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,created_at,updated_at) VALUES(900030,'active','admin','fixture',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),UTC_TIMESTAMP(),UTC_TIMESTAMP());")
  cls.state={'version':1,'days':{},'profile':{'nickname':'Fixture','age':28,'height':175,'weight':68,'daysPerWeek':3,'goal':'增肌塑形','experience':'新手','venue':'在家','focus':'全身','trainingDays':[1,3,5]},'drafts':[],'importedPlan':''}
  cls.worker=ThreadingHTTPServer(('127.0.0.1',18787),Worker);threading.Thread(target=cls.worker.serve_forever,daemon=True).start()
  cls.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
  password='Synthetic-v2-admin-password';digest=subprocess.check_output(['php','-r','echo password_hash("'+password+'",PASSWORD_DEFAULT);'],text=True)
  sql("DELETE FROM admin_accounts WHERE username='v2-fixture';INSERT INTO admin_accounts(username,password_hash,role,created_at) VALUES('v2-fixture','"+digest+"','super_admin',UTC_TIMESTAMP())")
  html=cls.opener.open(ADMIN).read().decode();cls.csrf=re.search('name="csrf" value="([a-f0-9]+)"',html).group(1);cls.form({'action':'login','username':'v2-fixture','password':password})
 @classmethod
 def form(cls,fields):
  html=cls.opener.open(ADMIN,data=urllib.parse.urlencode({**fields,'csrf':cls.csrf}).encode()).read().decode()
  match=re.search('name="csrf" value="([a-f0-9]+)"',html)
  if match:cls.csrf=match.group(1)
  return html
 @classmethod
 def tearDownClass(cls):
  cls.worker.shutdown();cls.worker.server_close()
 def upload(self,state):
  _,env=api('/me/state');return api('/me/state','PUT',{'base_revision':env['revision'],'state':state})
 def test_01_swift_compatible_state_round_trip(self):
  state=copy.deepcopy(self.state)
  state['days'][TODAY]={'exercises':[],'meals':[],'health':{'date':TODAY,'timeZone':'Asia/Shanghai','updatedAt':STAMP,'steps':{'value':1,'source':{'id':'fixture','name':'Fixture'}},'workouts':[]}}
  self.assertEqual(self.upload(state)[0],200)
  _,value=api('/me/state');self.assertIsInstance(value['state']['days'],dict)
 def test_02_invalid_nested_state_rejected_preserving_old_data(self):
  _,before=api('/me/state')
  for bad in [{'2026-02-31':{'exercises':[],'meals':[]}},{TODAY:{'exercises':[],'meals':[{'id':'11111111-1111-1111-1111-111111111111'}]}},{TODAY:{'exercises':[{'id':'11111111-1111-1111-1111-111111111111','name':'x','muscle':'x','sets':[{'id':'22222222-2222-2222-2222-222222222222','weight':1,'reps':'10','completed':False}]}],'meals':[]}}]:
   state=copy.deepcopy(self.state);state['days']=bad;self.assertEqual(self.upload(state)[0],400)
  _,after=api('/me/state');self.assertEqual(after['revision'],before['revision']);self.assertEqual(after['state'],before['state'])
 def test_03_malformed_tombstone_is_400(self):
  state=copy.deepcopy(self.state);state['deletedMealIDs']='invalid';self.assertEqual(self.upload(state)[0],400)
 def test_04_rejected_weekly_submission_is_not_reserved(self):
  global REJECT_POST
  REJECT_POST=True;job='33333333-3333-3333-3333-333333333333'
  try:
   self.assertEqual(api('/me/weekly/jobs/'+job,'POST',{'id':job,'kind':'weekly_review','date':TODAY,'payload':{}})[0],400)
   self.assertEqual(api('/me/weekly/jobs/'+job)[0],404)
   self.assertEqual(sql("SELECT COUNT(*) FROM ai_user_jobs WHERE user_id=900030 AND client_job_id='"+job+"'"),'0')
  finally:REJECT_POST=False
 def test_05_empty_and_impossible_seasons_not_publishable(self):
  sql(f"INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES(900030,'v2-fixture-empty','Fixture','Fixture','Fixture','{TODAY}','{TODAY}','{TODAY}','draft',1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
  self.form({'action':'club_season_publish','season_id':900030});self.assertEqual(sql('SELECT status FROM club_seasons WHERE id=900030'),'draft')
  sql("INSERT INTO club_tasks(id,season_id,title,detail,metric,target,created_at) VALUES(900030,900030,'Fixture','Fixture','training_days',2,UTC_TIMESTAMP());INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,inventory,created_at) VALUES(900030,900030,900030,'Fixture','Fixture','physical',1,UTC_TIMESTAMP())")
  self.form({'action':'club_season_publish','season_id':900030});self.assertEqual(sql('SELECT status FROM club_seasons WHERE id=900030'),'draft')
  sql('UPDATE club_tasks SET target=1 WHERE id=900030');self.form({'action':'club_season_publish','season_id':900030});self.assertEqual(sql('SELECT status FROM club_seasons WHERE id=900030'),'published')
  sql(f"INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES(900031,'v2-fixture-overlap','Fixture','Fixture','Fixture','{TODAY}','{TODAY}','{TODAY}','draft',1,UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO club_tasks(id,season_id,title,detail,metric,target,created_at) VALUES(900031,900031,'Fixture','Fixture','health_days',1,UTC_TIMESTAMP());INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,created_at) VALUES(900031,900031,900031,'Fixture','Fixture','badge',UTC_TIMESTAMP())")
  self.form({'action':'club_season_publish','season_id':900031});self.assertEqual(sql('SELECT status FROM club_seasons WHERE id=900031'),'draft')
 def test_06_shipped_problem_cannot_clear_tracking_cancel_or_free_inventory(self):
  sql("INSERT INTO club_reward_claims(season_id,reward_id,user_id,status,recipient,phone,region,address,tracking_company,tracking_number,shipped_at,created_at,updated_at) VALUES(900030,900030,900030,'shipped','Fixture','13800138000','Fixture','Fixture','Fixture','fixture-track',UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP())")
  claim=sql('SELECT id FROM club_reward_claims WHERE user_id=900030')
  self.form({'action':'club_claim_status','claim_id':claim,'status':'problem','tracking_company':'','tracking_number':''})
  self.assertEqual(sql('SELECT tracking_number FROM club_reward_claims WHERE id='+claim),'fixture-track')
  self.form({'action':'club_claim_status','claim_id':claim,'status':'cancelled','tracking_company':'','tracking_number':''});self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+claim),'problem')
  self.assertEqual(api('/club/rewards/900030/cancel','POST',{})[0],409)
  self.assertEqual(api('/club/rewards/900030/received','POST',{})[0],200)
 def test_07_archived_history_and_earned_claim_survive_expired_membership(self):
  self.assertEqual(api('/club/seasons/900030/join','POST',{})[0],200)
  sql("DELETE FROM club_reward_claims WHERE user_id=900030;UPDATE club_tasks SET metric='health_days' WHERE id=900030;UPDATE club_seasons SET status='archived' WHERE id=900030;UPDATE membership_entitlements SET status='expired',expires_at='2000-01-01' WHERE user_id=900030")
  status,value=api('/club/history');self.assertEqual(status,200);self.assertEqual(value['items'][0]['season']['id'],900030);self.assertTrue(value['items'][0]['rewards'][0]['unlocked'])
  body={'recipient':'测试人','phone':'13800138000','region':'测试地区','address':'测试街道 1 号','size':'M'}
  self.assertEqual(api('/club/rewards/900030/claim','POST',body)[0],200)
  self.assertEqual(api('/club/rewards/900030/cancel','POST',{})[0],200)
  sql("UPDATE membership_entitlements SET status='active',expires_at=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY) WHERE user_id=900030")
 def test_08_notification_flags_preserved_and_explicitly_disableable(self):
  sql("INSERT INTO notification_templates(category,name,title,body,enabled,default_enabled,sound,badge,active,created_at,updated_at) VALUES('system','v2-fixture-notice','Fixture','Fixture body',1,1,1,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
  tid=sql("SELECT id FROM notification_templates WHERE name='v2-fixture-notice'")
  fields={'action':'notification_template_update','id':tid,'category':'system','name':'v2-fixture-notice','title':'New','body':'New body','enabled':1,'default_enabled':1}
  self.form(fields);self.assertEqual(sql('SELECT CONCAT(sound,badge) FROM notification_templates WHERE id='+tid),'11')
  self.form({**fields,'delivery_flags_present':1});self.assertEqual(sql('SELECT CONCAT(sound,badge) FROM notification_templates WHERE id='+tid),'00')
 def test_09_fast_deletion_durable_partial_failure_and_retry(self):
  global DELETE_FAILURE_AT,DELETE_COUNT
  token='v2-delete-'+'e'*50;digest=hashlib.sha256(token.encode()).hexdigest()
  sql("INSERT INTO users(id,status,created_at,updated_at) VALUES(900032,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES(900032,'"+digest+"',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY));INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,created_at,updated_at) VALUES(900032,'active','admin','fixture',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),UTC_TIMESTAMP(),UTC_TIMESTAMP())")
  for job in ['44444444-4444-4444-4444-444444444444','55555555-5555-5555-5555-555555555555']:
   self.assertEqual(api('/me/ai/jobs','POST',{'id':job,'kind':'report','date':TODAY,'payload':{}},token=token)[0],202)
  start=time.monotonic();self.assertEqual(api('/me','DELETE',{'confirmation':'DELETE'},token=token,timeout=2)[0],202);self.assertLess(time.monotonic()-start,1.5)
  self.assertEqual(api('/me','DELETE',{'confirmation':'DELETE'},token=token)[0],202);self.assertEqual(api('/me/deletion',token=token)[1]['accepted'],True)
  self.assertEqual(sql('SELECT COUNT(*) FROM account_deletions WHERE user_id=900032'),'1');self.assertEqual(api('/me',token=token)[0],401)
  DELETE_COUNT=0;DELETE_FAILURE_AT=2
  command="require '"+str(ROOT/'account-server/public/account-deletion.php')+"';$c=require '"+str(ROOT/'account-server/config.php')+"';$db=new PDO($c['dsn'],$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);$r=$db->query('SELECT * FROM account_deletions WHERE user_id=900032')->fetch();echo json_encode(processAccountDeletion($db,$c,$r));"
  first=subprocess.check_output(['php','-r',command],text=True);self.assertEqual(first,'false')
  self.assertEqual(sql('SELECT status FROM users WHERE id=900032'),'disabled');self.assertEqual(sql('SELECT JSON_LENGTH(job_ids) FROM account_deletions WHERE user_id=900032'),'1')
  DELETE_FAILURE_AT=0;second=subprocess.check_output(['php','-r',command],text=True);self.assertEqual(second,'true')
  self.assertEqual(sql('SELECT COUNT(*) FROM users WHERE id=900032'),'0');self.assertEqual(api('/me/deletion',token=token)[1]['status'],'completed')
 def test_10_reward_catalog_images_are_immutable_and_swap_to_empty_clears_old_photo(self):
  png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/1lQAAAAASUVORK5CYII=')
  def upload(fields,content=png,filename='fixture.png',mime='image/png'):
   boundary='v2-synthetic-boundary'
   fields={**fields,'csrf':self.csrf}
   parts=[f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k,v in fields.items()]
   parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="{filename}"\r\nContent-Type: {mime}\r\n\r\n'.encode()+content+b'\r\n')
   body=b''.join(parts)+f'--{boundary}--\r\n'.encode();request=urllib.request.Request(ADMIN,data=body,headers={'Content-Type':'multipart/form-data; boundary='+boundary})
   self.opener.open(request).read()
  fields={'action':'reward_catalog_create','name':'v2-fixture-image','kind':'badge','icon':'seal','detail':'Fixture','active':1}
  upload(fields);catalog=sql("SELECT id FROM club_reward_catalog WHERE name='v2-fixture-image'");first=sql('SELECT image_path FROM club_reward_catalog WHERE id='+catalog)
  self.assertRegex(first,r'^catalog-[0-9]+-[a-f0-9]{16}\.png$')
  sql("UPDATE club_rewards SET catalog_id="+catalog+",image_path='"+first+"' WHERE id=900031")
  upload({**fields,'action':'reward_catalog_update','id':catalog});second=sql('SELECT image_path FROM club_reward_catalog WHERE id='+catalog)
  self.assertNotEqual(first,second);self.assertEqual(sql('SELECT image_path FROM club_rewards WHERE id=900031'),first)
  sql("INSERT INTO club_reward_catalog(kind,name,detail,icon,active,created_at,updated_at) VALUES('badge','v2-fixture-no-image','Fixture','seal',1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
  new=sql("SELECT id FROM club_reward_catalog WHERE name='v2-fixture-no-image'")
  self.form({'action':'club_season_update','season_id':900031,'title':'Fixture','subtitle':'Fixture','official_note':'Fixture official note','rules_text':'Fixture season rules','starts_on':TODAY,'ends_on':TODAY,'join_deadline':TODAY,'capacity':1,'task_title[900031]':'Fixture','task_detail[900031]':'Fixture','task_target[900031]':1,'task_metric[900031]':'health_days','reward_title[900031]':'Fixture','reward_detail[900031]':'Fixture','reward_type[900031]':'badge','reward_icon[900031]':'seal','reward_catalog_id[900031]':new})
  self.assertEqual(sql('SELECT COALESCE(image_path,"NULL") FROM club_rewards WHERE id=900031'),'NULL')
  upload({**fields,'action':'reward_catalog_create','name':'v2-fixture-svg'},content=b'<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>',filename='fixture.svg',mime='image/svg+xml')
  self.assertEqual(sql("SELECT COUNT(*) FROM club_reward_catalog WHERE name='v2-fixture-svg'"),'0')
 def test_11_publish_race_cannot_leave_two_overlapping_published_seasons(self):
  tomorrow=(dt.date.fromisoformat(TODAY)+dt.timedelta(days=1)).isoformat()
  for i in [900034,900035]:
   sql(f"INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES({i},'v2-fixture-race-{i}','Fixture','Fixture','Fixture','{tomorrow}','{tomorrow}','{tomorrow}','draft',1,UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO club_tasks(id,season_id,title,detail,metric,target,created_at) VALUES({i},{i},'Fixture','Fixture','health_days',1,UTC_TIMESTAMP());INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,created_at) VALUES({i},{i},{i},'Fixture','Fixture','badge',UTC_TIMESTAMP())")
  barrier=threading.Barrier(2)
  def publish(i):
   opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()));html=opener.open(ADMIN).read().decode();csrf=re.search('name="csrf" value="([a-f0-9]+)"',html).group(1)
   html=opener.open(ADMIN,data=urllib.parse.urlencode({'action':'login','username':'v2-fixture','password':'Synthetic-v2-admin-password','csrf':csrf}).encode()).read().decode();csrf=re.search('name="csrf" value="([a-f0-9]+)"',html).group(1);barrier.wait()
   opener.open(ADMIN,data=urllib.parse.urlencode({'action':'club_season_publish','season_id':i,'csrf':csrf}).encode()).read()
  with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(publish,[900034,900035]))
  self.assertEqual(sql("SELECT COUNT(*) FROM club_seasons WHERE id IN (900034,900035) AND status='published'"),'1')

 def test_12_shipping_pagination_reaches_records_beyond_old_200_limit(self):
  sql('DELETE FROM users WHERE id BETWEEN 900100 AND 900304')
  values=','.join(f"({i},'active',UTC_TIMESTAMP(),UTC_TIMESTAMP())" for i in range(900100,900305))
  sql('INSERT INTO users(id,status,created_at,updated_at) VALUES'+values)
  try:
   values=','.join(f"(900030,900030,{i},'delivered','v2-pagination-{i}','13800138000','Fixture','Fixture',UTC_TIMESTAMP(),UTC_TIMESTAMP())" for i in range(900100,900305))
   sql('INSERT INTO club_reward_claims(season_id,reward_id,user_id,status,recipient,phone,region,address,created_at,updated_at) VALUES'+values)
   html=self.opener.open(ADMIN+'?p=shipping&status=delivered&page=5').read().decode()
   ids=re.findall('name="claim_id" value="([0-9]+)"',html)
   self.assertEqual(len(ids),5)
   self.assertIn('v2-pagination-900100',html);self.assertNotIn('v2-pagination-900304',html)
   self.assertIn('上一页',html);self.assertNotIn('下一页 →',html)
   first=self.opener.open(ADMIN+'?p=shipping&status=delivered&page=1').read().decode()
   self.assertEqual(len(re.findall('name="claim_id" value="([0-9]+)"',first)),50)
   self.assertIn('下一页 →',first)
  finally:sql('DELETE FROM users WHERE id BETWEEN 900100 AND 900304')

if __name__=='__main__':
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(Acceptance);result=unittest.TextTestRunner(verbosity=2).run(suite)
 Path(ROOT/'v2-http-result.json').write_text(json.dumps({'run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful()}),encoding='utf-8')
 raise SystemExit(not result.wasSuccessful())
