"""Task-based Admin regressions. Run against explicitly prepared synthetic fixtures only."""
import hashlib
import html
import json
import os
from pathlib import Path
import re
import unittest
import uuid
from test_admin_v2_http import Session, public_config
import urllib.request

class AdminWorkspaceHttp(unittest.TestCase):
    def setUp(self):
        self.session=Session(); self.session.login('v2-super')

    def tearDown(self):
        self.session.logout()

    def test_new_operations_pages_enforce_roles(self):
        self.session.get('/admin/?p=subscriptions')
        _, body = self.session.get('/admin/?p=alerts')
        self.assertIn('待处理异常', body)
        for role, subscriptions, alerts in [('operator',200,200),('support',403,403),('readonly',403,200),('content',403,403)]:
            client=Session(); client.login('v2-'+role)
            try:
                client.get('/admin/?p=subscriptions',expect=subscriptions)
                client.get('/admin/?p=alerts',expect=alerts)
                if role=='content':
                    client.post({'action':'notification_plan_publish','id':1,'expected_revision':1},expect=403)
            finally: client.logout()

    def test_notification_draft_roundtrip_and_stale_edit(self):
        _, body=self.session.get('/admin/?p=notifications&tab=plans&new=1')
        template=re.search(r'<option value="(\d+)"',body).group(1)
        name='原生时间草稿 '+uuid.uuid4().hex[:8]
        fields={'name':name,'template_id':template,'weekdays[]':'1','send_time':'09:05','timezone':'Asia/Shanghai','audience_mode':'selected','user_refs':'NO. 010001'}
        _, location, _=self.session.post({'action':'notification_plan_create',**fields})
        _, body=self.session.get(html.unescape(location))
        self.assertIn(name,body); self.assertIn('value="09:05"',body)
        self.assertIn('NO. 010001',body); self.assertNotIn('暂停自动发送</button>',body)
        plan=re.search(r'name="id" value="(\d+)"',body).group(1)
        self.session.post({'action':'notification_plan_update','id':plan,'expected_revision':1,**fields,'name':name+' 修改'})
        _, _, body=self.session.post({'action':'notification_plan_update','id':plan,'expected_revision':1,**fields,'name':'陈旧修改不得保存'},expect=200)
        self.assertIn('其他窗口修改',body)
        _,body=self.session.get('/admin/?p=notifications&tab=plans&plan='+plan)
        self.assertIn(name+' 修改',body);self.assertNotIn('陈旧修改不得保存',body)

    def version(self,tab='features'):
        _,body=self.session.get('/admin/?p=config&tab='+tab)
        return int(re.search(r'name="draft_version" value="(\d+)"',body).group(1))

    def test_server_sections_and_versioned_assets(self):
        _,body=self.session.get('/admin/?p=config&tab=announcement')
        self.assertIn('name="announcement_title"',body)
        self.assertNotIn('name="minimum_build"',body)
        self.assertNotIn('name="onboarding_welcome_title"',body)
        _,body=self.session.get('/admin/?p=notifications&tab=receipts')
        self.assertIn('value="notification_test"',body)
        self.assertNotIn('value="notification_template_create"',body)
        _,body=self.session.get('/admin/?p=user&id=1&tab=ops-follow')
        self.assertIn('value="member_note"',body)
        self.assertNotIn('value="delete_user"',body)
        root=Path(__file__).resolve().parents[1]/'account-server/admin'
        for name in ['style.css','app.js']:
            self.assertIn('/admin/'+name+'?v='+hashlib.sha256((root/name).read_bytes()).hexdigest()[:12],body)
        self.assertEqual(body.count('<nav class="primary-nav"'),1)

    def test_scoped_saves_publish_exact_values(self):
        _,before,_=public_config(); preserved=before['config']['onboarding_content']
        version=self.version('announcement')
        self.session.post({'action':'config_save_draft','config_section':'announcement','draft_version':version,'ui_section':'announcement','announcement_enabled':'1','announcement_title':'栏目独立保存','announcement_body':'其他栏目内容必须保留。'})
        version=self.version('versions')
        self.session.post({'action':'config_save_draft','config_section':'versions','draft_version':version,'ui_section':'versions','minimum_build':'136','latest_build':'137'})
        self.session.post({'action':'config_publish','draft_version':self.version()})
        _,after,_=public_config()
        self.assertEqual(after['config']['announcement']['title'],'栏目独立保存')
        self.assertEqual(after['config']['minimum_build'],136)
        self.assertEqual(after['config']['onboarding_content'],preserved)
        self.assertEqual(after['config']['ai_native_home'],before['config']['ai_native_home'])
        self.assertEqual(after['config']['ai_enabled'],before['config']['ai_enabled'])

    def test_member_save_stays_in_section_and_persists(self):
        text='HTTP drawer regression '+uuid.uuid4().hex[:12]
        _,location,_=self.session.post({'action':'member_note','user_id':1,'note':text,'ui_section':'ops-follow'})
        self.assertIn('tab=ops-follow',location)
        _,body=self.session.get(html.unescape(location))
        self.assertIn(text,body)
        self.assertNotIn('value="delete_user"',body)

    def test_feedback_reply_duplicate_and_stale_write(self):
        ticket=os.environ['BOJI_WORKSPACE_TICKET']
        _,body=self.session.get('/admin/?p=feedback&ticket='+ticket)
        self.assertIn('class="feedback-workspace"',body)
        self.assertIn('ticket-conversation',body)
        last=re.search(r'name="last_message_id" value="(\d+)"',body).group(1)
        text='回复持久化核对 '+uuid.uuid4().hex[:8]
        fields={'action':'feedback_reply','ticket_id':ticket,'last_message_id':last,'client_id':str(uuid.uuid4()),'text':text}
        self.session.post(fields)
        self.session.post(fields) # Same payload/client key is idempotent.
        _,body=self.session.get('/admin/?p=feedback&ticket='+ticket)
        self.assertEqual(body.count(text),1)
        fresh=re.search(r'name="last_message_id" value="(\d+)"',body).group(1)
        self.assertGreater(int(fresh),int(last))
        stale={**fields,'client_id':str(uuid.uuid4()),'text':'过期窗口回复仍应保留'}
        _,_,body=self.session.post(stale,expect=200)
        self.assertIn('用户已有新消息',body)
        self.assertIn(stale['text'],body)
        self.session.post({'action':'feedback_status','ticket_id':ticket,'last_message_id':fresh,'status':'closed'})
        _,body=self.session.get('/admin/?p=feedback&ticket='+ticket)
        self.assertIn('重新打开',body)

    def test_displayed_member_number_and_csrf(self):
        note='编号定位 '+uuid.uuid4().hex[:8]
        _,location,_=self.session.post({'action':'member_note','user_id':'NO. 010001','note':note,'ui_section':'ops-follow'})
        self.assertIn('id=1',location)
        _,body=self.session.get('/admin/?p=user&id=1&tab=ops-follow');self.assertIn(note,body)
        self.session.post({'action':'member_note','user_id':'1','note':'invalid csrf must not persist','csrf':'not-a-session-token'},expect=403)
        _,body=self.session.get('/admin/?p=user&id=1&tab=ops-follow');self.assertNotIn('invalid csrf must not persist',body)
        _,body=self.session.get('/admin/?p=users&q=NO.%20010001');self.assertIn('NO. 010001',body)

    def test_ai_capacity_gate_and_router_reach_real_consumer(self):
        def engine(path):
            request=urllib.request.Request('http://127.0.0.1:18792/v1/admin/ai/'+path,headers={'Authorization':'Bearer independent-audit-loopback-only-token-1234'})
            with urllib.request.urlopen(request,timeout=5) as response:return json.load(response)
        settings=engine('settings');snapshot=engine('router');router=snapshot['controls']
        fields={key:settings[key] for key in ['account_daily_limit','daily_limit','pending_limit','account_pending_limit','worker_limit']}
        try:
            self.session.post({'action':'ai_capacity',**fields,'worker_limit':2,'account_daily_limit':7,'reason':'isolated control persistence','ui_section':'ai-capacity'})
            actual=engine('settings');self.assertEqual(actual['worker_limit'],2);self.assertEqual(actual['account_daily_limit'],7)
            self.session.post({'action':'ai_control','accepting':'off','reason':'isolated gate check'})
            self.assertFalse(engine('settings')['accepting'])
            self.session.post({'action':'ai_router_update','enabled':1,'weight_chat':60,'weight_reference':70,'weight_proposal':70,'weight_complex':50,'weight_vision':50,'current_password':'TestSuper!2026','reason':'isolated model allocation'})
            self.assertAlmostEqual(engine('router')['controls']['weights']['chat'],0.6)
        finally:
            self.session.post({'action':'ai_capacity',**fields,'reason':'restore isolated defaults'})
            self.session.post({'action':'ai_control','accepting':'on' if settings['accepting'] else 'off','reason':'restore isolated gate'})
            saved={ 'weight_'+key:round(value*100) for key,value in router.get('weights',snapshot['default_weights_deepseek']).items()}
            self.session.post({'action':'ai_router_update',**saved,**({'enabled':1} if router.get('enabled',True) else {}),'current_password':'TestSuper!2026','reason':'restore isolated router'})

    def test_paginated_catalog_and_template_edit(self):
        _,first=self.session.get('/admin/?p=badges')
        _,second=self.session.get('/admin/?p=badges&page=2')
        ids=lambda body:re.findall(r'name="id" value="(\d+)"',body)
        self.assertEqual(len(set(ids(first))),20)
        self.assertTrue(ids(second))
        self.assertFalse(set(ids(first))&set(ids(second)))
        _,body=self.session.get('/admin/?p=notifications&tab=templates')
        self.assertEqual(body.count('value="notification_template_update"'),20)
        match=re.search(r'name="id" value="(\d+)"',body); self.assertIsNotNone(match)
        identifier=match.group(1)
        name='HTTP template '+uuid.uuid4().hex[:8]
        self.session.post({'action':'notification_template_update','id':identifier,'name':name,'category':'training','title':'准备训练','body':'该开始今天的训练了。','delivery_flags_present':1,'enabled':1,'sound':1,'ui_section':'templates'})
        # Filtering/sort can move an item to another page; fetch the first two bounded pages.
        rendered=''.join(self.session.get('/admin/?p=notifications&tab=templates&page='+str(p))[1] for p in [1,2])
        self.assertIn(name,rendered)

if __name__=='__main__':unittest.main(verbosity=2)
