"""Integration regression using synthetic data in bojiclub_repair_test only.

Run PHP's test router on 127.0.0.1:18082, with an isolated config and mock worker.
Never run this against production.
"""
import base64
import copy
import datetime
import hashlib
import http.cookiejar
import json
import re
from pathlib import Path
import subprocess
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB = 'bojiclub_repair_v2_test'
BASE = 'http://127.0.0.1:18082/account/v1'
TOKEN = 'synthetic-test-session-token-' + 'a' * 40
TODAY = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).date().isoformat()
MEDIA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jpg'
MEAL = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
JOB = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
DELETIONS = []
DELETE_FAILURE = False
WORKER_JOBS = {}

def sql(command):
    return subprocess.check_output(['mysql', '-N', DB, '-e', command], text=True).strip()

def publish_app_config(mutate):
    """Upsert published app_config keys in the isolated test DB.

    Returns (existed, original_published_json) so the caller can restore them.
    """
    existed = sql("SELECT COUNT(*) FROM app_config WHERE config_key='app'") != '0'
    original = sql("SELECT COALESCE(published_json,'{}') FROM app_config WHERE config_key='app'")
    current = json.loads(original or '{}')
    current.update(mutate)
    payload = json.dumps(current, ensure_ascii=False).replace("'", "''")
    if existed:
        sql("UPDATE app_config SET published_json='" + payload +
            "',published_version=published_version+1,published_at=UTC_TIMESTAMP() WHERE config_key='app'")
    else:
        sql("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) "
            "VALUES('app','" + payload + "','" + payload + "',1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
    return existed, original

def restore_app_config(existed, original):
    if existed:
        payload = (original or '{}').replace("'", "''")
        sql("UPDATE app_config SET published_json='" + payload + "' WHERE config_key='app'")
    else:
        sql("DELETE FROM app_config WHERE config_key='app'")

def api(path, method='GET', body=None, content_type='application/json', token=TOKEN):
    data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE+path, data=data, method=method,
        headers={'Authorization': 'Bearer '+token, 'Content-Type': content_type})
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    raw = response.read()
    try: value = json.loads(raw)
    except ValueError: value = raw
    return response.status, value

class Worker(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        WORKER_JOBS[payload['id']] = payload
        self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'id':payload['id'],'status':'queued'}).encode())
    def do_DELETE(self):
        global DELETE_FAILURE
        DELETIONS.append(self.path.rsplit('/',1)[-1])
        if DELETE_FAILURE:
            DELETE_FAILURE=False
            self.send_response(503);self.end_headers();self.wfile.write(b'{"error":"synthetic outage"}');return
        self.send_response(200);self.end_headers();self.wfile.write(b'{"deleted":true}')
    def do_GET(self):
        job=WORKER_JOBS.get(self.path.rsplit('/',1)[-1],{})
        result={'status':'succeeded','result':{'kind':job['kind']}} if job.get('fixture_completed') else {'status':'queued'}
        self.send_response(200);self.end_headers();self.wfile.write(json.dumps(result).encode())

class AccountHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.worker=ThreadingHTTPServer(('127.0.0.1',18787),Worker)
        threading.Thread(target=cls.worker.serve_forever,daemon=True).start()
        # All IDs are synthetic and only the isolated database is touched.
        sql("DELETE FROM account_deletions WHERE token_hash='"+hashlib.sha256(TOKEN.encode()).hexdigest()+"'; DELETE FROM users WHERE id=900010; DELETE FROM club_rewards WHERE season_id=900010; DELETE FROM club_tasks WHERE season_id=900010; DELETE FROM club_seasons WHERE id=900010;")
        sql(f"""INSERT INTO users(id,status,created_at,updated_at) VALUES(900010,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP());
        INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES(900010,'{hashlib.sha256(TOKEN.encode()).hexdigest()}',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY));
        INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,created_at,updated_at) VALUES(900010,'active','admin','fixture',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),UTC_TIMESTAMP(),UTC_TIMESTAMP());
        INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,created_at,updated_at) VALUES(900010,'fixture','Fixture','fixture','fixture','{TODAY}','{TODAY}','{TODAY}','published',UTC_TIMESTAMP(),UTC_TIMESTAMP());
        INSERT INTO club_tasks(id,season_id,title,metric,target,created_at) VALUES(900010,900010,'Health','health_days',1,UTC_TIMESTAMP());
        INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,inventory,claim_deadline,created_at) VALUES(900010,900010,900010,'Gift','Fixture','physical',1,'{TODAY}',UTC_TIMESTAMP());
        INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,inventory,claim_deadline,created_at) VALUES(900011,900010,900010,'Gift2','Fixture','physical',1,'{TODAY}',UTC_TIMESTAMP());
        INSERT INTO member_admin_profiles(user_id,tags_json,updated_by,updated_at) VALUES(900010,'[]',1,UTC_TIMESTAMP());
        INSERT INTO member_admin_notes(user_id,admin_id,note,created_at) VALUES(900010,1,'Synthetic',UTC_TIMESTAMP());""")
        cls.state={'version':1,'days':{TODAY:{'exercises':[],'meals':[], 'health':{'date':TODAY,'timeZone':'Asia/Shanghai','updatedAt':800000000,'steps':{'value':0,'source':{'id':'fixture','name':'Fixture'}},'workouts':[]}}},
            'profile':{'nickname':'Fixture','goal':'test','experience':'test','venue':'test','focus':'test','age':28,'height':175,'weight':68,'daysPerWeek':3},'drafts':[],'importedPlan':''}
        status,_=api('/me/state','PUT',{'base_revision':0,'state':cls.state})
        if status!=200:raise RuntimeError('Test setup PUT state failed '+str(status))
        status,_=api('/club/seasons/900010/join','POST',{})
        if status!=200:raise RuntimeError('Test setup join failed '+str(status))

    @classmethod
    def tearDownClass(cls):
        cls.worker.shutdown();cls.worker.server_close()

    def test_01_account_and_expired_session(self):
        self.assertEqual(api('/me')[0],200)
        self.assertEqual(api('/me',token='x'*60)[0],401)
        self.assertEqual(api('/auth/code/request','POST',{'phone':'18800000000'})[0],403)
        self.assertEqual(api('/auth/code/verify','POST',{'phone':'18800000000','code':'123456'})[0],403)

    def test_01b_admin_shipping_page_and_transition_guard(self):
        password='Synthetic-test-admin-password'
        digest=subprocess.check_output(['php','-r','echo password_hash("'+password+'",PASSWORD_DEFAULT);'],text=True)
        sql("DELETE FROM admin_accounts WHERE username='fixture'; INSERT INTO admin_accounts(username,password_hash,role,created_at) VALUES('fixture','"+digest+"','super_admin',UTC_TIMESTAMP())")
        opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        url='http://127.0.0.1:18082/admin/'
        page=opener.open(url).read().decode()
        csrf=re.search('name="csrf" value="([a-f0-9]+)"',page).group(1)
        form=urllib.parse.urlencode({'action':'login','username':'fixture','password':password,'csrf':csrf}).encode()
        opener.open(url,data=form).read()
        shipping=opener.open(url+'?p=shipping')
        self.assertEqual(shipping.status,200)
        html=shipping.read().decode();self.assertNotIn('Fatal error',html)
        # Synthetic already shipped claim cannot be cancelled to free inventory.
        sql("INSERT INTO club_reward_claims(season_id,reward_id,user_id,status,recipient,phone,region,address,tracking_company,tracking_number,created_at,updated_at) VALUES(900010,900010,900010,'shipped','Fixture','13800138000','Fixture','Fixture address','Fixture','fixture-track',UTC_TIMESTAMP(),UTC_TIMESTAMP())")
        claim=sql('SELECT id FROM club_reward_claims WHERE user_id=900010')
        csrf=re.search('name="csrf" value="([a-f0-9]+)"',html).group(1)
        form=urllib.parse.urlencode({'action':'club_claim_status','claim_id':claim,'status':'cancelled','tracking_company':'Fixture','tracking_number':'fixture-track','csrf':csrf}).encode()
        opener.open(url,data=form).read()
        self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+claim),'shipped')
        sql('DELETE FROM club_reward_claims WHERE id='+claim)
        # Actual multipart upload at the documented per-image maximum, in the test DB only.
        png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/1lQAAAAASUVORK5CYII=')
        image=png+b'\0'*(5*1024*1024-len(png))
        boundary='synthetic-fixture-boundary'
        fields={'csrf':csrf,'action':'reward_catalog_create','kind':'physical','name':'Synthetic upload fixture','detail':'Synthetic','icon':'gift','default_inventory':'1','max_per_user':'10'}
        parts=[f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode() for key,value in fields.items()]
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="fixture.png"\r\nContent-Type: image/png\r\n\r\n'.encode()+image+b'\r\n')
        body=b''.join(parts)+f'--{boundary}--\r\n'.encode()
        request=urllib.request.Request(url,data=body,headers={'Content-Type':'multipart/form-data; boundary='+boundary})
        opener.open(request).read()
        value=sql("SELECT CONCAT(image_path,':',max_per_user) FROM club_reward_catalog WHERE name='Synthetic upload fixture' ORDER BY id DESC LIMIT 1")
        self.assertRegex(value,r'^catalog-[0-9]+-[a-f0-9]{16}\.png:1$')

    def test_02_health_uses_encoded_metric_without_has_data(self):
        status,value=api('/club/current');self.assertEqual(status,200)
        self.assertEqual(value['tasks'][0]['current'],1)
        self.assertTrue(value['rewards'][0]['unlocked'])

    def test_03_claim_deadline_cancel_reapply_and_season_limit(self):
        claim={'recipient':'测试人','phone':'13800138000','region':'测试地区','address':'测试街道 1 号','size':'M'}
        sql("UPDATE club_rewards SET claim_deadline='2000-01-01' WHERE id=900010")
        self.assertEqual(api('/club/rewards/900010/claim','POST',claim)[0],409)
        sql(f"UPDATE club_rewards SET claim_deadline='{TODAY}' WHERE id=900010")
        self.assertEqual(api('/club/rewards/900010/claim','POST',claim)[0],200)
        first=sql('SELECT id FROM club_reward_claims WHERE user_id=900010 AND reward_id=900010')
        self.assertEqual(api('/club/rewards/900011/claim','POST',claim)[0],409)
        sql("UPDATE club_reward_claims SET status='cancelled' WHERE user_id=900010")
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda reward:api(f'/club/rewards/{reward}/claim','POST',claim)[0],[900010,900011]))
        self.assertEqual(sorted(results),[200,409])
        sql("UPDATE club_reward_claims SET status='cancelled' WHERE user_id=900010")
        self.assertEqual(api('/club/rewards/900010/claim','POST',claim)[0],200)
        self.assertEqual(sql('SELECT id FROM club_reward_claims WHERE user_id=900010 AND reward_id=900010'),first)
        sql("UPDATE club_reward_claims SET status='cancelled' WHERE user_id=900010")

    def test_04_state_conflict_empty_dictionary_and_photo_delete(self):
        # Embedded synthetic JPEG, no personal image data.
        image=base64.b64decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCfAAf/2Q==')
        self.assertEqual(api('/me/media/'+MEDIA,'PUT',image,'image/jpeg')[0],200)
        status,envelope=api('/me/state');self.assertEqual(status,200)
        state=copy.deepcopy(envelope['state'])
        state['days'][TODAY]['meals']=[{'id':MEAL,'name':'fixture','category':'午餐','calories':1,'protein':1,'carbs':1,'fat':1,'photoFilename':MEDIA,'photoRemoteID':MEDIA}]
        status,_=api('/me/state','PUT',{'base_revision':envelope['revision'],'state':state});self.assertEqual(status,200)
        self.assertEqual(api('/me/media/'+MEDIA)[0],200)
        self.assertEqual(api('/me/state','PUT',{'base_revision':0,'state':state})[0],409)
        _,envelope=api('/me/state');state=envelope['state'];state['days'][TODAY]['meals']=[];state['deletedMealIDs']=[MEAL];state['deletedMediaIDs']=[MEDIA]
        status,_=api('/me/state','PUT',{'base_revision':envelope['revision'],'state':state});self.assertEqual(status,200)
        self.assertEqual(api('/me/media/'+MEDIA)[0],404)
        self.assertEqual(api('/me/media/'+MEDIA,'PUT',image,'image/jpeg')[0],410)
        self.assertEqual(sql('SELECT COUNT(*) FROM user_media WHERE user_id=900010'),'0')
        _,envelope=api('/me/state');self.assertIsInstance(envelope['state']['days'],dict)

    def test_04b_reward_progress_verifies_ai_and_saved_workouts(self):
        ids=['dddddddd-dddd-dddd-dddd-dddddddddddd','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee']
        for job in ids:
            self.assertEqual(api('/me/ai/jobs','POST',{'id':job,'kind':'report','date':TODAY,'payload':{},'fixture_completed':True})[0],200)
            self.assertEqual(api('/me/ai/jobs/'+job)[0],200)
        sql("""INSERT INTO club_tasks(id,season_id,title,metric,target,created_at) VALUES
            (900011,900010,'Report','daily_reports',2,UTC_TIMESTAMP()),
            (900012,900010,'Weekly','weekly_reviews',1,UTC_TIMESTAMP()),
            (900013,900010,'Training','training_days',1,UTC_TIMESTAMP())""")
        _,envelope=api('/me/state');state=envelope['state']
        state['aiJobs']=[{'id':job,'digest':'fixture','created':800000000,'consumed':False,'status':'succeeded','request':{'id':job,'kind':'report','date':TODAY,'payload':{}},'result':{'kind':'report','notes':[]}} for job in ids]
        state['days'][TODAY]['weeklyReview']={'id':'ffffffff-ffff-ffff-ffff-ffffffffffff','date':TODAY,'survey':{'bodyFatSource':'','fatigue':'适中','pain':'无疼痛','difficulty':'合适','diet':'','notes':'','days':1},'photos':[],'jobID':'ffffffff-ffff-ffff-ffff-ffffffffffff','status':'succeeded','applied':False,'updatedAt':800000000,'result':{'kind':'weekly_review','summary':'Fixture','training':'Fixture','nutrition':'Fixture','recovery':'Fixture','appearance':'Fixture','photoFeedback':[],'decision':'keep','reason':'Fixture','notes':[],'sessions':[]},'baseline':{}}
        state['days'][TODAY]['exercises']=[{'id':'11111111-1111-1111-1111-111111111111','name':'Fixture','muscle':'Fixture','sets':[{'id':'22222222-2222-2222-2222-222222222222','weight':1,'reps':1,'completed':True}]}]
        self.assertEqual(api('/me/state','PUT',{'base_revision':envelope['revision'],'state':state})[0],200)
        _,season=api('/club/current');counts={task['metric']:task['current'] for task in season['tasks']}
        self.assertEqual(counts['daily_reports'],1)
        self.assertEqual(counts['weekly_reviews'],0)
        self.assertEqual(counts['training_days'],0)
        _,envelope=api('/me/state');self.assertIsInstance(envelope['state']['days'][TODAY]['weeklyReview']['baseline'],dict)
        state=envelope['state'];state['days'][TODAY]['workoutSavedAt']=1
        self.assertEqual(api('/me/state','PUT',{'base_revision':envelope['revision'],'state':state})[0],200)
        _,season=api('/club/current');counts={task['metric']:task['current'] for task in season['tasks']}
        self.assertEqual(counts['training_days'],1)

    def test_04z_coach_dormancy_flag_keeps_other_ai_kinds(self):
        """P2：coach 链路按 app_config.coach_enabled 休眠（默认关），其余 4 项不受影响。

        覆盖 提交 / 轮询 / SSE / 对话读取 四类入口，以及开关打开后的整体回退。
        """
        COACH_ID='a4a4a4a4-a4a4-a4a4-a4a4-a4a4a4a4a4a4'
        SERVER_ID='b5b5b5b5-b5b5-b5b5-b5b5-b5b5b5b5b5b5'
        POLL_COACH='c6c6c6c6-c6c6-c6c6-c6c6-c6c6c6c6c6c6'
        POLL_REPORT='d7d7d7d7-d7d7-d7d7-d7d7-d7d7d7d7d7d7'
        PLAN_ID='e8e8e8e8-e8e8-e8e8-e8e8-e8e8e8e8e8e8'
        FOOD_ID='f9f9f9f9-f9f9-f9f9-f9f9-f9f9f9f9f9f9'
        REPORT_ID='1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d1a2b'
        WEEKLY_ID='2b3c4d5e-2b3c-2b3c-2b3c-2b3c4d5e2b3c'
        def error_code(value): return value.get('error_code') if isinstance(value, dict) else None
        def assert_dormant(status, value, label):
            self.assertEqual((status, error_code(value)), (503, 'coach_disabled'), label+' 应被 coach 闸门拦截')
        def assert_not_dormant(status, value, label):
            self.assertFalse(status == 503 and error_code(value) == 'coach_disabled', label+' 不应被 coach 闸门拦截：'+str((status, value)))
        existed, original = publish_app_config({'coach_enabled': False})
        try:
            # 1) 休眠：提交 / 对话读取 / SSE 创建 一律 503 + coach_disabled
            assert_dormant(*api('/me/ai/jobs','POST',{'id':COACH_ID,'kind':'coach','date':TODAY,'payload':{}}), 'coach 提交')
            assert_dormant(*api('/me/ai/conversations'), '对话列表')
            assert_dormant(*api('/me/ai/conversations/fixtureconv/runs','POST',{'client_message_id':COACH_ID}), 'SSE Run 创建')
            # 2) 轮询只拦 coach 任务，report 任务照常
            sql("INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) "
                "VALUES(900010,'"+POLL_COACH+"','"+SERVER_ID+"','coach',UTC_TIMESTAMP()),"
                "(900010,'"+POLL_REPORT+"','"+SERVER_ID+"','report',UTC_TIMESTAMP())")
            assert_dormant(*api('/me/ai/jobs/'+POLL_COACH), 'coach 轮询')
            self.assertEqual(api('/me/ai/jobs/'+POLL_REPORT)[0], 200, 'report 轮询不受影响')
            # 3) 其余 4 项（生成计划 / 饮食识别 / 日报 / 周报）全部通过闸门
            for job_id, kind in ((PLAN_ID,'generate_plan'), (FOOD_ID,'food'), (REPORT_ID,'report')):
                status, value = api('/me/ai/jobs','POST',{'id':job_id,'kind':kind,'date':TODAY,'payload':{},'fixture_completed':True})
                assert_not_dormant(status, value, kind+' 提交')
            self.assertEqual(api('/me/ai/jobs/'+REPORT_ID)[0], 200, 'report 提交后可轮询')
            status, value = api('/me/weekly/jobs/'+WEEKLY_ID,'POST',{'kind':'weekly_review'})
            assert_not_dormant(status, value, 'weekly_review 提交')
            # 4) 打开 flag：整体回退，无需发版
            publish_app_config({'coach_enabled': True})
            self.assertEqual(api('/me/ai/conversations')[0], 200, 'flag 打开后对话读取恢复')
            status, value = api('/me/ai/jobs','POST',{'id':COACH_ID,'kind':'coach','date':TODAY,'payload':{}})
            assert_not_dormant(status, value, 'flag 打开后的 coach 提交')
        finally:
            restore_app_config(existed, original)
            sql("DELETE FROM ai_user_jobs WHERE user_id=900010 AND client_job_id IN ('"+POLL_COACH+"','"+POLL_REPORT+"')")

    def test_05_weekly_mapping_and_account_delete_cleanup(self):
        global DELETE_FAILURE
        self.assertEqual(api('/me/weekly/jobs/'+JOB,'POST',{'kind':'weekly_review'})[0],200)
        server_job=sql("SELECT server_job_id FROM ai_user_jobs WHERE user_id=900010 AND kind='weekly_review'")
        self.assertTrue(server_job)
        # Verify nonmembers can still read/delete a task; only new work requires membership.
        sql("UPDATE membership_entitlements SET status='expired' WHERE user_id=900010")
        self.assertEqual(api('/me/weekly/jobs/'+JOB)[0],200)
        self.assertEqual(api('/me/weekly/jobs/'+JOB,'POST',{'kind':'weekly_review'})[0],403)
        DELETE_FAILURE=True
        self.assertEqual(api('/me','DELETE',{'confirmation':'DELETE'})[0],202)
        self.assertEqual(api('/me')[0],401)
        self.assertEqual(api('/me','DELETE',{'confirmation':'DELETE'})[0],202)
        root=Path(__file__).resolve().parents[1]
        command="require '"+str(root/'account-server/public/account-deletion.php')+"';$c=require '"+str(root/'account-server/config.php')+"';$db=new PDO($c['dsn'],$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);$r=$db->query('SELECT * FROM account_deletions WHERE user_id=900010')->fetch();echo json_encode(processAccountDeletion($db,$c,$r));"
        self.assertEqual(subprocess.check_output(['php','-r',command],text=True),'false')
        self.assertEqual(subprocess.check_output(['php','-r',command],text=True),'true')
        self.assertIn(server_job,DELETIONS)
        for table in ['users','member_admin_profiles','member_admin_notes','ai_user_jobs','deleted_media']:
            column='id' if table=='users' else 'user_id'
            self.assertEqual(sql(f'SELECT COUNT(*) FROM {table} WHERE {column}=900010'),'0')
        self.assertEqual(api('/me')[0],401)

if __name__=='__main__':unittest.main(verbosity=2)
