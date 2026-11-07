"""HTTP contract checks in a disposable SQLite store; no paid providers."""
import http.client,json,sys,tempfile,threading,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from server import JobStore,make_server

class EdgeAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.server=make_server(JobStore(Path(cls.temp.name)/'jobs.sqlite3'),type('Router',(),{'providers':[]})(),'x'*32,port=0)
        threading.Thread(target=cls.server.serve_forever,daemon=True).start()
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.temp.cleanup()
    def request(self,method,path,body=None,authorized=True):
        connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        try:
            connection.request(method,path,body,{'Authorization':'Bearer '+('x'*32 if authorized else 'bad'),'Content-Type':'application/json'})
            response=connection.getresponse();return response.status,json.loads(response.read())
        finally:connection.close()
    def test_bad_query_returns_400_and_next_request_still_works(self):
        for path in ['/v1/admin/ai/overview?days=abc','/v1/admin/ai/tasks?page=abc','/v1/admin/ai/tasks?days=1.5','/v1/admin/ai/tasks?page=%F0%9F%98%80']:
            with self.subTest(path=path):
                self.assertEqual(self.request('GET',path)[0],400)
                self.assertEqual(self.request('GET','/v1/admin/ai/overview?days=7')[0],200)
    def test_non_object_json_never_changes_settings(self):
        for path in ['/v1/jobs/metadata','/v1/admin/ai/settings','/v1/admin/ai/providers','/v1/jobs']:
            for body in ['[]','null','42','"text"','true','{']:
                with self.subTest(path=path,body=body):self.assertEqual(self.request('POST',path,body)[0],400)
        self.assertTrue(self.request('GET','/v1/admin/ai/settings')[1]['accepting'])
    def test_valid_empty_metadata_and_settings_continue_working(self):
        self.assertEqual(self.request('POST','/v1/jobs/metadata','{"ids":[]}'),(200,{'items':[]}))
        for accepting in (False, True):
            code,settings=self.request('POST','/v1/admin/ai/settings',json.dumps({'accepting':accepting}))
            self.assertEqual(code,200);self.assertEqual(settings['accepting'],accepting)
            self.assertEqual({key:settings[key] for key in ['daily_limit','account_daily_limit','pending_limit','worker_limit']},
                             {'daily_limit':0,'account_daily_limit':0,'pending_limit':800,'worker_limit':3})
    def test_authorization_precedes_body_validation(self):
        self.assertEqual(self.request('POST','/v1/admin/ai/settings','[]',False)[0],404)

if __name__=='__main__':unittest.main(verbosity=2)
