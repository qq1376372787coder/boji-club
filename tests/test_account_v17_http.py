"""Actual admin form regression on an isolated test database."""
import re, unittest
import test_account_v2_http as fixture
sql=fixture.sql
class Acceptance(unittest.TestCase):
    form=fixture.Acceptance.__dict__['form']
    @classmethod
    def setUpClass(cls):
        fixture.Acceptance.setUpClass.__func__(cls)
        today=fixture.TODAY
        sql("DELETE FROM users WHERE id=917200; DELETE FROM club_seasons WHERE id=917100; DELETE FROM club_reward_catalog WHERE name LIKE 'v17-form-%';")
        sql(f"INSERT INTO club_seasons(id,slug,title,subtitle,official_note,rules_text,starts_on,ends_on,join_deadline,status,capacity,created_at,updated_at) VALUES(917100,'v17-form','Fixture','Fixture','0123456789AB','0123456789AB','{today}','{today}','{today}','draft',10,UTC_TIMESTAMP(),UTC_TIMESTAMP()); INSERT INTO club_tasks(id,season_id,title,detail,metric,target,sort_order,created_at) VALUES(917101,917100,'Task-A','Fixture','training_days',1,10,UTC_TIMESTAMP()),(917102,917100,'Task-B','Fixture','training_days',1,20,UTC_TIMESTAMP()); INSERT INTO club_rewards(id,season_id,task_id,title,detail,reward_type,icon,sort_order,created_at) VALUES(917101,917100,917101,'Reward-A','Fixture','badge','seal',99,UTC_TIMESTAMP()),(917102,917100,917102,'Reward-B','Fixture','badge','seal',1,UTC_TIMESTAMP());")
    @classmethod
    def tearDownClass(cls):
        sql("DELETE FROM users WHERE id=917200; DELETE FROM club_seasons WHERE id=917100; DELETE FROM club_reward_catalog WHERE name LIKE 'v17-form-%';")
        fixture.Acceptance.tearDownClass.__func__(cls)
    def test_01_task_rewards_stay_paired_when_sort_orders_differ(self):
        html=self.opener.open(fixture.ADMIN+'?p=club&season=917100').read().decode()
        a=html[html.index('name="task_title[917101]"'):html.index('name="task_title[917102]"')]
        self.assertIn('name="reward_title[917101]"',a)
        self.assertNotIn('name="reward_title[917102]"',a)
        self.assertIn('name="reward_inventory[917101]"',a)
    def test_02_switching_badge_to_physical_catalog_uses_catalog_inventory(self):
        sql("INSERT INTO club_reward_catalog(kind,name,detail,icon,default_inventory,max_per_user,active,created_at,updated_at) VALUES('physical','v17-form-gift','Fixture','gift',15,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
        cat=sql("SELECT id FROM club_reward_catalog WHERE name='v17-form-gift'")
        fields={'action':'club_season_update','season_id':'917100','title':'Fixture','subtitle':'Fixture','official_note':'0123456789AB','rules_text':'0123456789AB','starts_on':fixture.TODAY,'ends_on':fixture.TODAY,'join_deadline':fixture.TODAY,'capacity':'10'}
        for i in (917101,917102):
            fields.update({f'task_title[{i}]':'Task',f'task_detail[{i}]':'Fixture',f'task_target[{i}]':'1',f'task_metric[{i}]':'training_days',f'reward_title[{i}]':'Reward',f'reward_detail[{i}]':'Fixture',f'reward_type[{i}]':'badge',f'reward_icon[{i}]':'seal'})
        fields['reward_catalog_id[917101]']=cat
        self.form(fields)
        self.assertEqual(sql('SELECT CONCAT(reward_type,":",inventory) FROM club_rewards WHERE id=917101'),'physical:15')
    def test_03_appending_task_keeps_reward_sort_equal(self):
        cat=sql("SELECT id FROM club_reward_catalog WHERE name='v17-form-gift'")
        self.form({'action':'club_task_create','season_id':'917100','title':'Append','detail':'Fixture','metric':'meal_days','target':'1','catalog_id':cat})
        self.assertEqual(sql('SELECT COUNT(*) FROM club_tasks t JOIN club_rewards r ON r.task_id=t.id WHERE t.season_id=917100 AND t.title="Append" AND t.sort_order=r.sort_order'),'1')
    def test_04_global_shipping_form_can_review_and_pack_claim(self):
        sql("INSERT INTO users(id,status,created_at,updated_at) VALUES(917200,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()); INSERT INTO club_reward_claims(season_id,reward_id,user_id,recipient,phone,region,address,status,created_at,updated_at) VALUES(917100,917101,917200,'Fixture','13800138000','Fixture','Fixture address','pending',UTC_TIMESTAMP(),UTC_TIMESTAMP())")
        claim=sql('SELECT id FROM club_reward_claims WHERE user_id=917200')
        html=self.opener.open(fixture.ADMIN+'?p=shipping').read().decode()
        forms=re.findall(r'<form.*?</form>',html,flags=re.S)
        matched=[f for f in forms if f'name="claim_id" value="{claim}"' in f]
        self.assertEqual(len(matched),1)
        self.assertIn('name="review_confirmed"',matched[0])
        self.assertIn('name="operator_note"',matched[0])
        self.form({'action':'club_claim_status','claim_id':claim,'status':'confirmed','review_confirmed':'1','operator_note':'人工已检查训练饮食记录满足活动要求'})
        self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+claim),'confirmed')
        self.form({'action':'club_claim_status','claim_id':claim,'status':'packing','operator_note':'人工已检查训练饮食记录满足活动要求'})
        self.assertEqual(sql('SELECT status FROM club_reward_claims WHERE id='+claim),'packing')
        self.assertEqual(sql('SELECT reviewed_at IS NOT NULL FROM club_reward_claims WHERE id='+claim),'1')
if __name__=='__main__':unittest.main(verbosity=2)
