"""Synthetic account/claim acceptance. Never point this suite at production."""
import copy,datetime as dt,hashlib,json,re,subprocess,time,unittest,urllib.request,urllib.error
from pathlib import Path
import test_account_v2_http as fixture
DB=fixture.DB; ROOT=fixture.ROOT; api=fixture.api; sql=fixture.sql
USER=901080; TOKEN='v6-fixture-'+'k'*50
class Acceptance(unittest.TestCase):
    form=fixture.Acceptance.__dict__['form']
    @classmethod
    def setUpClass(cls):
        assert 'test' in DB and DB.startswith('bojiclub_repair_')
        fixture.Acceptance.setUpClass.__func__(cls)
        sql(f"DELETE FROM users WHERE id={USER};DELETE FROM club_rewards WHERE season_id={USER};DELETE FROM club_tasks WHERE season_id={USER};DELETE FROM club_seasons WHERE id={USER};")
        today=fixture.TODAY
        sql(f"INSERT INTO users(id,status,created_at,updated_at) VALUES({USER},'active',UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES({USER},'{hashlib.sha256(TOKEN.encode()).hexdigest()}',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY));INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,created_at,updated_at) VALUES({USER},'active','admin','fixture',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO club_seasons(id,slug,title,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES({USER},'v6-fixture','Fixture','Fixture','Fixture','{today}','{today}','{today}','published',100,UTC_TIMESTAMP(),UTC_TIMESTAMP());INSERT INTO club_tasks(id,season_id,title,detail,metric,target,created_at) VALUES({USER},{USER},'Fixture','Fixture','health_days',1,UTC_TIMESTAMP());INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,inventory,created_at) VALUES({USER},{USER},{USER},'Fixture','Fixture','physical',10,UTC_TIMESTAMP()),({USER+1},{USER},{USER},'Legacy gift 2','Fixture','physical',10,UTC_TIMESTAMP());INSERT INTO club_enrollments(season_id,user_id,rules_version,joined_at) VALUES({USER},{USER},'v6-fixture',UTC_TIMESTAMP());")
        state=copy.deepcopy(cls.state);state['days'][today]={'exercises':[],'meals':[],'health':{'date':today,'timeZone':'Asia/Shanghai','updatedAt':800000000,'steps':{'value':1,'source':{'id':'fixture','name':'Fixture'}},'workouts':[]}}
        status,_=api('/me/state','PUT',{'base_revision':0,'state':state},TOKEN);assert status==200
        status,_=api(f'/club/rewards/{USER}/claim','POST',{'recipient':'测试人','phone':'13800138000','region':'测试地区','address':'测试街道一号'},TOKEN);assert status==200
        cls.claim=sql(f'SELECT id FROM club_reward_claims WHERE user_id={USER}')
    @classmethod
    def tearDownClass(cls):fixture.Acceptance.tearDownClass.__func__(cls)
    def test_01_other_reward_is_blocked_before_address_form(self):
        status,value=api('/club/history',token=TOKEN);self.assertEqual(status,200)
        item=next(x for x in value['items'] if x['season']['id']==USER)
        rewards={r['id']:r for r in item['rewards']}
        self.assertFalse(rewards[USER]['blocked_by_other_claim']);self.assertTrue(rewards[USER+1]['blocked_by_other_claim'])
    def test_02_unreviewed_claim_cannot_confirm_or_ship_even_via_problem(self):
        sql('UPDATE club_reward_claims SET status=\'problem\' WHERE id='+self.claim)
        for status in ['confirmed','packing','shipped','delivered']:
            self.form({'action':'club_claim_status','claim_id':self.claim,'status':status,'tracking_company':'Fixture','tracking_number':'Fixture','operator_note':'未核验'})
            self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+self.claim),'problem')
        self.form({'action':'club_claim_status','claim_id':self.claim,'status':'confirmed','review_confirmed':1,'operator_note':'已核对本期训练饮食记录与领取资格'})
        self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+self.claim),'confirmed')
        self.assertEqual(sql('SELECT reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL FROM club_reward_claims WHERE id='+self.claim),'1')
        self.form({'action':'club_claim_status','claim_id':self.claim,'status':'shipped','tracking_company':'Fixture','tracking_number':'Fixture'})
        self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+self.claim),'shipped')
    def test_03_read_and_unauthorized_requests_ignore_rule_writer_lock(self):
        script=f"$c=require '{ROOT}/account-server/config.php';$d=new PDO($c['dsn'],$c['db_user'],$c['db_password']);require '{ROOT}/account-server/public/club-lock.php';clubRulesLock($d);echo 'LOCKED'.PHP_EOL;flush();sleep(8);"
        process=subprocess.Popen(['php','-r',script],stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(),'LOCKED')
            start=time.monotonic();self.assertEqual(api('/club/history',token=TOKEN,timeout=2)[0],200);self.assertLess(time.monotonic()-start,2)
            start=time.monotonic();self.assertEqual(api('/club/current',token='invalid',timeout=2)[0],401);self.assertLess(time.monotonic()-start,2)
        finally:process.terminate();process.wait(timeout=3)
    def test_04_more_than_twenty_thousand_valid_deletion_ids_sync(self):
        state=copy.deepcopy(self.state);state['deletedExerciseIDs']=[f'{i:08x}-0000-0000-0000-000000000000' for i in range(20001)]
        _,env=api('/me/state',token=TOKEN)
        self.assertEqual(api('/me/state','PUT',{'base_revision':env['revision'],'state':state},TOKEN)[0],200)
        _,read=api('/me/state',token=TOKEN);self.assertEqual(len(read['state']['deletedExerciseIDs']),20001)

if __name__=='__main__':unittest.main(verbosity=2)
