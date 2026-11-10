"""Synthetic outage, schema, concurrent admission and durable diagnostic checks."""
import copy, json, sys, tempfile, unittest, threading, uuid, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core as core
import server
import datetime as dt
from unittest.mock import patch
from test_backend_v2 import request, result

class Stability(unittest.TestCase):
    def providers(self):
        return [core.Provider(n,'https://example.invalid','fixture','synthetic',60,True,True,p) for n,p in [('deepseek',10),('minimax',20)]]
    def routed_request(self):
        value=request();value['payload']['_routing_version']=3;return value
    def ordered_router(self, transport, clock=None):
        router=core.Router(self.providers(),transport,clock=clock or time.monotonic)
        router.routing_metrics.order=lambda providers,request:sorted(providers,key=lambda p:p.priority)
        return router
    def test_invalid_content_does_not_disable_unrelated_tasks(self):
        router=core.Router(self.providers())
        for _ in range(5): router.record(router.providers[0],core.AIError('invalid_output','fixture',True,True))
        self.assertTrue(router.acquire(router.providers[0]))
    def test_network_errors_still_open_circuit(self):
        router=core.Router(self.providers())
        for _ in range(3): router.record(router.providers[0],core.AIError('upstream_timeout','fixture',True,True))
        self.assertFalse(router.acquire(router.providers[0]))
    def test_schema_reason_is_fixed_not_exception_content(self):
        self.assertEqual(core.output_reason(ValueError('secret user data')), 'schema_invalid')
        self.assertEqual(core.output_reason(KeyError('private input')), 'schema_missing_field')
        self.assertEqual(core.output_reason(ValueError('unavailable home movement or equipment')), 'plan_equipment')
    def test_invalid_plan_falls_back_with_scoped_repair_hint(self):
        seen=[];events=[]
        def transport(p,messages,limit):
            seen.append((p.name,messages))
            value=result()
            if p.name=='deepseek': value['sessions'][0]['date']='2030-01-01'
            return value,{}
        value,provider,_=self.ordered_router(transport).run(self.routed_request(),events.append)
        self.assertEqual(provider,'minimax'); self.assertEqual(events[0]['reason'],'plan_dates')
        self.assertEqual(len(seen),2); self.assertIn('日期',seen[1][1][-1]['content'])
        self.assertEqual(seen[0][1],core.messages_for(self.routed_request()))
        self.assertEqual(value['kind'],'plan')
    def test_all_invalid_stops_after_three_calls(self):
        seen=[]
        def transport(p,*_): seen.append(p.name); return {'kind':'plan','sessions':[]},{}
        with self.assertRaises(core.AIError) as e: self.ordered_router(transport).run(self.routed_request())
        self.assertEqual(seen,['deepseek','minimax']);self.assertFalse(e.exception.retryable)
    def test_safe_json_fence_and_whitespace(self):
        self.assertEqual(core.decode_model_json(' \n```json\n{"kind":"plan"}\n```\n'), {'kind':'plan'})
        self.assertEqual(core.decode_model_json(' {"kind":"plan"} '), {'kind':'plan'})
    def test_duplicate_fields_and_mixed_prose_rejected(self):
        for text in ['{"kind":"plan","kind":"meal"}','说明：{"kind":"plan"}','```json\n{"kind":"plan"}\n```\n解释','{"kind":']:
            with self.subTest(text=text),self.assertRaises(ValueError): core.decode_model_json(text)
    def test_provenance_warning_is_not_false_measurement_claim(self):
        for content in ['营养估算不是精确称重，存在误差。','不能视为精确称重的结果。','没有估算全天摄入，记录未确认完整。','没有估算依据，无法给出这个数字。','这里没有精确称重，营养数字有估算误差。','记录未提供精确称重，不应声称全部实测。','不要把记录数字当成精确称重。','不是没有估算，而是估算仍有不确定性。','没有“精确称重”，这些是记录的估算。','不能当作**精确称重**的结果。']:
            with self.subTest(content=content): self.assertFalse(core.unsupported_measurement_claim(content))
    def test_fabricated_measurement_is_still_rejected(self):
        for content in ['这些数据都是实测。','这餐没有估算，均为实测。','你的营养值来自精确称重。','这份不是精确称重；另一份是精确称重。','不是没记训练，营养都是实测。']:
            with self.subTest(content=content): self.assertTrue(core.unsupported_measurement_claim(content))
    def test_concurrent_duplicate_is_one_persisted_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=server.JobStore(Path(tmp)/'tasks.db'); id=str(uuid.uuid4())
            with ThreadPoolExecutor(max_workers=12) as pool: values=list(pool.map(lambda _:store.create(id,request()),range(40)))
            self.assertEqual({v['id'] for v in values},{id})
            with store.connect() as db: self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],1)
    def test_daily_capacity_differs_from_temporary_busy_and_keeps_old_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=server.JobStore(Path(tmp)/'tasks.db');old=store.create('existing',request(),maximum_per_day=1)
            with self.assertRaises(core.AIError) as caught: store.create('new',request(),maximum_per_day=1)
            self.assertEqual(caught.exception.code,'capacity')
            existing=store.create('existing',request(),maximum_per_day=1)
            self.assertEqual((existing['id'],existing['status']),(old['id'],old['status']))
            store.complete('existing',{},'fixture','fixture')
            with self.assertRaises(core.AIError) as caught: store.create('new',request(),maximum_per_day=1)
            self.assertEqual(caught.exception.code,'daily_capacity')
    def test_capacity_is_atomic_under_concurrent_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=server.JobStore(Path(tmp)/'tasks.db')
            store.update_settings({'pending_limit':30})
            def submit(_):
                try: store.create(str(uuid.uuid4()),request()); return 'accepted'
                except core.AIError as e: return e.code
            with ThreadPoolExecutor(max_workers=12) as pool: states=list(pool.map(submit,range(45)))
            self.assertEqual(states.count('accepted'),30);self.assertEqual(states.count('capacity'),15)
    def test_diagnostics_survive_restart_and_are_not_public(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'tasks.db'; store=server.JobStore(path);store.create('fixture',request())
            store.attempt('fixture',{'provider':'longcat','model':'fixture','outcome':'invalid_output','duration_ms':1,'usage':{},'reason':'plan_dates'})
            store.attempt('fixture',{'provider':'mimo','model':'fixture','outcome':'success','duration_ms':1,'usage':{}})
            store=server.JobStore(path)
            self.assertEqual(store.admin_overview()['validation_reasons'],[{'code':'plan_dates','count':1}])
            self.assertEqual(store.admin_overview()['recovered_jobs'],1)
            self.assertNotIn('validation_reason',store.get('fixture'))
    def test_deleted_job_cannot_regain_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=server.JobStore(Path(tmp)/'tasks.db');store.delete_private('fixture')
            store.attempt('fixture',{'provider':'fixture','model':'fixture','outcome':'invalid_output','duration_ms':1,'usage':{},'reason':'plan_dates'})
            self.assertEqual(store.admin_overview()['attempts'],0)
    @patch.object(server, 'validate_new_plan_start',
        lambda value: core.validate_new_plan_start(value, dt.datetime(2026,9,30,12,tzinfo=dt.timezone.utc)))
    def test_real_http_worker_fallback_and_resubmission_are_durable(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=server.JobStore(Path(tmp)/'tasks.db');seen=[]
            def transport(provider,*_):
                seen.append(provider.name)
                if provider.name!='minimax':raise core.AIError('upstream_timeout','synthetic',True,True)
                return result(),{}
            router=self.ordered_router(transport)
            http=server.make_server(store,router,'synthetic',port=0);worker=server.Workers(store,router)
            threading.Thread(target=http.serve_forever,daemon=True).start();worker.thread.start()
            base='http://127.0.0.1:'+str(http.server_address[1]);job_id=str(uuid.uuid4());payload={**self.routed_request(),'id':job_id}
            def call(path,body=None):
                req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer synthetic','Content-Type':'application/json'})
                with urllib.request.urlopen(req,timeout=5) as res:return json.load(res)
            try:
                call('/v1/jobs',payload);call('/v1/jobs',payload)
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    value=call('/v1/jobs/'+job_id)
                    if value['status']=='succeeded':break
                    time.sleep(.02)
                self.assertEqual(value['status'],'succeeded');self.assertEqual(seen,['deepseek','minimax'])
                self.assertEqual(call('/v1/jobs',payload)['status'],'succeeded')
                self.assertEqual(len(seen),2)
                self.assertEqual(server.JobStore(Path(tmp)/'tasks.db').get(job_id)['result']['kind'],'plan')
            finally:
                http.shutdown();http.server_close();worker.stop.set();worker.thread.join(2);worker.pool.shutdown(wait=True)

if __name__=='__main__':unittest.main()
