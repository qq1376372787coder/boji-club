import io
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import ai_core
import food_core
import fitness_intelligence as fitness
from provider_stream import answer_prefix, read_chat_stream
from server import JobStore


class FinalRepairTests(unittest.TestCase):
    def test_nutrition_http_search_and_compute_share_global_engine(self):
        from server import make_server
        from threading import Thread
        from urllib.request import Request, urlopen
        with tempfile.TemporaryDirectory() as directory:
            server = make_server(JobStore(Path(directory) / 'jobs.sqlite3'), ai_core.Router([]), 'synthetic-test-token', port=0)
            thread = Thread(target=server.serve_forever, daemon=True); thread.start()
            def post(path, body):
                request = Request('http://127.0.0.1:' + str(server.server_port) + path,
                                  data=json.dumps(body).encode(), headers={'Authorization':'Bearer synthetic-test-token','Content-Type':'application/json'})
                with urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    return json.load(response)['result']
            try:
                self.assertTrue(post('/v1/nutrition/search', {'query':'香蕉'})['candidates'])
                unknown = post('/v1/nutrition/compute', {'items':[{'name':'香蕉','amount':1,'unit':'根'}]})
                self.assertIsNone(unknown['totals']['calories'])
                self.assertFalse(unknown['totals_complete'])
                known = post('/v1/nutrition/compute', {'items':[{'name':'香蕉','amount':1,'unit':'根','edible_grams':100}]})
                self.assertEqual(known['totals']['calories'],89)
            finally:
                server.shutdown(); server.server_close(); thread.join(2)

    def test_model_cannot_verify_its_own_nutrition(self):
        raw = {'kind': 'meal', 'is_food': True, 'name': '未知食物', 'components': [
            {'name': '未知食物', 'amount': 100, 'unit': 'g', 'basis': 'visible',
             'calories': 180, 'protein': 10, 'carbs': 26, 'fat': 4,
             'per_100g': {'calories': 180, 'protein': 10, 'carbs': 26, 'fat': 4},
             'source_kind': 'label', 'label_verified': True, 'user_confirmed': True}]}
        result = food_core.clean_food(raw, [], (ai_core.text, ai_core.number, ai_core.sequence))
        self.assertTrue(result['requiresReview'])
        self.assertNotIn(result['components'][0]['sourceDatabase'], ('VERIFIED_LABEL', 'USER_CONFIRMED'))
        self.assertLess(result['components'][0]['confidenceLow'], result['components'][0]['confidenceHigh'])

    def test_breathing_and_denial(self):
        facts = dict(coverage_score=1, training_days=1, completed_sets=12, data_freshness_days=0)
        for question in ('我现在喘得很厉害，说不出整句话，还能练吗', '我胸前区疼痛', '我不能呼吸'):
            self.assertEqual(fitness.assess_readiness(facts, question)['decision'], 'SAFETY_ESCALATION')
        self.assertEqual(fitness.assess_readiness(facts, '没有胸痛，今天状态正常')['decision'], 'TRAIN_AS_PLANNED')
        self.assertEqual(fitness.assess_readiness(facts, '没有胸部疼痛')['decision'], 'TRAIN_AS_PLANNED')
        self.assertEqual(fitness.assess_readiness({**facts, 'general_guidance_only': True}, '今天能练吗')['decision'], 'ASK_FOLLOWUP')
        self.assertEqual(fitness.assess_readiness({**facts, 'general_guidance_only': True}, '胸痛')['decision'], 'SAFETY_ESCALATION')

    def test_answer_projection_never_leaks_nested_tools(self):
        self.assertIsNone(answer_prefix('{"tools":{"answer":"不该显示"}}'))
        self.assertIsNone(answer_prefix('{"notes":["\\\"coach\\\":{\\\"answer\\\":\\\"错误"],'))
        self.assertEqual(answer_prefix('{"kind":"coach","coach":{"answer":"中文回答'), '中文回答')
        self.assertEqual(answer_prefix('{"coach":{"answer":"换行\\n字符\\u4e2d'), '换行\n字符中')
        self.assertEqual(answer_prefix('{"coach":{"answer":"中文\\'), '中文')

    def test_real_stream_emits_before_done_and_rejects_truncation(self):
        frames = []
        for piece in ('{"kind":"coach","coach":{"answer":"第一段自然中文', '还在生成中的回答","source_ids":[],"actions":[]}}'):
            frames.append('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {'content': piece}, 'finish_reason': None}]}) + '\n\n')
        finish = 'data: ' + json.dumps({'choices': [{'delta': {}, 'finish_reason': 'stop'}]}) + '\n\ndata: [DONE]\n\n'
        observed = []
        response = io.BytesIO((''.join(frames) + finish).encode())
        data = read_chat_stream(response, float('inf'), lambda text: observed.append((text, response.tell())))
        self.assertTrue(observed)
        self.assertLess(observed[0][1], len(response.getvalue()))
        self.assertIn('还在生成', data['choices'][0]['message']['content'])
        with self.assertRaises(ValueError):
            read_chat_stream(io.BytesIO(''.join(frames).encode()), float('inf'), lambda _: None)

    def test_counted_food_is_not_treated_as_grams(self):
        import nutrition_engine as nutrition
        unknown = nutrition.compute_item({'name':'香蕉','amount':1,'unit':'根'})
        self.assertIsNone(unknown.edible_grams)
        self.assertIsNone(unknown.nutrients['calories'])
        self.assertIn('portion_requires_mass', unknown.flags)
        raw = {'kind':'meal','is_food':True,'name':'香蕉','components':[{'name':'香蕉','amount':1,'unit':'根','basis':'visible','calories':89,'protein':1.1,'carbs':22.8,'fat':.3}]}
        result = food_core.clean_food(raw, [], (ai_core.text, ai_core.number, ai_core.sequence))
        self.assertEqual(result['calories'],89)
        self.assertEqual(result['components'][0]['sourceKind'],'estimate')
        self.assertIsNone(result['components'][0]['sourceDatabase'])
        self.assertTrue(result['requiresReview'])
        explicit = nutrition.compute_item({'name':'香蕉','amount':1,'unit':'根','edible_grams':100})
        self.assertEqual(explicit.nutrients['calories'],89)

    def test_production_food_catalog_has_real_sources(self):
        import nutrition_engine as nutrition
        foods = nutrition.search_foods('香蕉')
        item = foods['candidates'][0]
        self.assertEqual(item['food_id'], 'usda-sr-173944')
        self.assertEqual(item['source_database'], 'USDA_FDC_SR_LEGACY')
        self.assertEqual(item['per_100g']['calories'], 89)
        self.assertIsNone(nutrition.match_food('香蕉', 'usda-sr-171688'))
        raw = json.loads((Path(__file__).resolve().parents[1] / 'backend/food-catalog-production.json').read_text())
        self.assertGreater(len(raw['foods']), 7000)
        self.assertEqual(raw['license'], 'CC0-1.0')

    def test_emergency_never_reaches_provider_or_tools(self):
        def must_not_call(*args):
            raise AssertionError('Emergency input must bypass providers')
        router = ai_core.Router([], transport=must_not_call)
        request = ai_core.validate_request({'kind':'coach','date':'2026-10-25','payload':{'version':1,'conversation_id':str(uuid.uuid4()),'question':'我现在喘得很厉害，说不出整句话，还能练吗','history':[],'days':[],'timeZone':'Asia/Shanghai'}})
        result, provider, model = router.run(request)
        self.assertEqual(provider, 'deterministic')
        self.assertIn('停止训练', result['coach']['answer'])
        self.assertFalse(result['coach'].get('capability_calls'))
        self.assertFalse(result['coach'].get('actions'))

    def test_router_stream_is_real_and_final_schema_still_validates(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Event, Thread
        ready, release = Event(), Event()
        raw = {'kind': 'coach', 'notes': [], 'coach': {'answer': '先核对当天登记的训练事实与实际状态。这里不能从少量记录推断动作质量或力量增长，请继续记录同一器械的完成组，等待有足够数据再比较。', 'source_ids': [], 'actions': []}}
        content = json.dumps(raw, ensure_ascii=False)
        cut = content.index('这里')
        class ProviderHandler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert body['stream'] is True
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                def send(piece, finish=None):
                    value = {'choices': [{'index': 0, 'delta': {'content': piece}, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode()); self.wfile.flush()
                send(content[:cut]); ready.set()
                assert release.wait(3)
                send(content[cut:]); send('', 'stop')
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        server = ThreadingHTTPServer(('127.0.0.1', 0), ProviderHandler)
        worker = Thread(target=server.serve_forever, daemon=True); worker.start()
        provider = ai_core.Provider('fixture', 'http://127.0.0.1:' + str(server.server_port), 'fixture', 'synthetic-token', timeout=5)
        router = ai_core.Router([provider])
        events, result, failures = [], [], []
        request = ai_core.validate_request({'kind':'coach', 'date':'2026-10-25', 'payload':{'version':1,'conversation_id':str(uuid.uuid4()),'question':'今天训练需要留意什么','history':[],'days':[],'timeZone':'Asia/Shanghai'}})
        def run():
            try: result.append(router.run(request, on_text=lambda kind, text: events.append((kind, text))))
            except Exception as error: failures.append(error)
        thread = Thread(target=run); thread.start()
        try:
            self.assertTrue(ready.wait(2))
            import time
            deadline = time.monotonic() + 2
            while not any(k == 'delta' for k, _ in events) and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(any(k == 'delta' for k, _ in events), 'Must display a real upstream delta before provider finishes')
            self.assertTrue(thread.is_alive())
            release.set(); thread.join(3)
            self.assertFalse(failures, repr(failures))
            self.assertEqual(result[0][0]['coach']['answer'], raw['coach']['answer'])
        finally:
            release.set(); thread.join(4); server.shutdown(); server.server_close(); worker.join(1)

    def test_stream_events_fenced_and_erased(self):
        with tempfile.TemporaryDirectory() as directory:
            store = JobStore(Path(directory) / 'jobs.sqlite3')
            job = str(uuid.uuid4())
            store.create(job, {'kind': 'coach', 'date': '2026-10-25', 'payload': {'days': [], 'history': [], 'question': '测试'}}, quota_owner='a' * 64)
            row = store.claim()
            token = row[3]
            self.assertFalse(store.append_stream(job, 'wrong', 'delta', '不能出现'))
            self.assertTrue(store.append_stream(job, token, 'reset', ''))
            self.assertTrue(store.append_stream(job, token, 'delta', '正在生成中文'))
            self.assertEqual(len(store.stream_events(job)['events']), 2)
            self.assertEqual(store.stream_events(job, 1)['events'][0]['text'], '正在生成中文')
            store.delete_private(job)
            self.assertIsNone(store.stream_events(job))
            self.assertFalse(store.append_stream(job, token, 'delta', '取消后的内容'))

if __name__ == '__main__':
    unittest.main()
