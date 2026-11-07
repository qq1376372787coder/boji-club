"""Isolated runtime test: real MariaDB concurrency and real Admin HTTP roles.
Run on a disposable host checkout after test_audit129_sql.php prepare + check.
Never calls the production AI service; the realtime stats upstream is a stub.
"""
import http.server, threading, urllib.request, urllib.parse, urllib.error, http.cookiejar
import subprocess, os, time, re, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
assert os.environ.get('BOJI_TEST_DSN_BASE'), 'explicit isolated DSN required'
def php(mode,*args):return subprocess.check_output(['php',str(ROOT/'tests/test_audit129_sql.php'),mode,*args],text=True).strip()
barrier=Path('/tmp/boji129-concurrent')
for ext in ['.locked','.release']:Path(str(barrier)+ext).unlink(missing_ok=True)
write=subprocess.Popen(['php',str(ROOT/'tests/test_audit129_sql.php'),'hold',str(barrier)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 deadline=time.monotonic()+8
 while not Path(str(barrier)+'.locked').exists():
  assert write.poll() is None,'writer failed before acquiring lock'
  assert time.monotonic()<deadline,'writer barrier timeout'
  time.sleep(.02)
 withdraw=subprocess.Popen(['php',str(ROOT/'tests/test_audit129_sql.php'),'withdraw102'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 time.sleep(.5)  # Allow MariaDB's InnoDB diagnostic snapshot to refresh.
 deadline=time.monotonic()+5;wait_seen=False
 while time.monotonic()<deadline:
  sql="SELECT COUNT(*) FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p ON p.ID=t.trx_mysql_thread_id WHERE p.DB='boji_audit129_test' AND t.trx_state='LOCK WAIT'"
  count=int(subprocess.check_output(['mariadb','--protocol=TCP','--host=127.0.0.1','--port=3306','--user=root','-Nse',sql],text=True).strip())
  if count:wait_seen=True;break
  assert withdraw.poll() is None,'withdrawal incorrectly passed held account lock'
  time.sleep(.25)
 assert wait_seen,'did not observe real InnoDB contention'
 Path(str(barrier)+'.release').write_text('1')
 out,err=write.communicate(timeout=10);assert write.returncode==0,(out,err)
 out2,err2=withdraw.communicate(timeout=10);assert withdraw.returncode==0,(out2,err2)
 status=json.loads(php('status102'));assert status=={'allowed':0,'operations':1},status
 print('PASS real concurrent write-before-withdrawal; observed InnoDB lock wait; one committed receipt preserved')
finally:
 if write.poll() is None:write.kill()
 if 'withdraw' in locals() and withdraw.poll() is None:withdraw.kill()
 for ext in ['.locked','.release']:Path(str(barrier)+ext).unlink(missing_ok=True)

subprocess.run(['php',str(ROOT/'tests/audit129_http_fixture.php')],check=True)
class Stats(http.server.BaseHTTPRequestHandler):
 count=0
 def do_GET(self):
  type(self).count+=1;self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"fixture":true}')
 def log_message(self,*args):pass
stub=http.server.ThreadingHTTPServer(('127.0.0.1',18130),Stats);threading.Thread(target=stub.serve_forever,daemon=True).start()
router=ROOT/'audit129_router.php';router.write_text("<?php if(parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH)==='/admin/')require __DIR__.'/account-server/admin/index.php';else http_response_code(404);")
log=open(ROOT/'audit129-http-server.log','w');web=subprocess.Popen(['php','-S','127.0.0.1:18129',str(router)],cwd=ROOT,stdout=log,stderr=log)
base='http://127.0.0.1:18129/admin/'
def get(opener,url,data=None):
 try:
  with opener.open(url,data=data,timeout=8) as response:return response.status,response.read(),response.headers.get('Content-Type','')
 except urllib.error.HTTPError as error:return error.code,error.read(),error.headers.get('Content-Type','')
checks=0
try:
 for _ in range(100):
  try:urllib.request.urlopen(base,timeout=.2).close();break
  except OSError:time.sleep(.02)
 endpoints=['?p=photo&id=101&media=12900000-0000-4000-8000-000000000070.jpg','?p=reward_photo&reward=129','?p=catalog_photo&id=129','?p=catalog_photo&id=130','?p=ai_live']
 guest=urllib.request.build_opener()
 for endpoint in endpoints:
  assert get(guest,base+endpoint)[0]==403,endpoint;checks+=1
 for role in ['super_admin','operator','support','readonly','content']:
  opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
  code,body,_=get(opener,base+'?p=login');csrf=re.search(rb'name="csrf" value="([^"]+)"',body).group(1).decode()
  data=urllib.parse.urlencode({'csrf':csrf,'action':'login','username':'fixture-'+role,'password':'fixture-password129'}).encode()
  code,body,_=get(opener,base,data);assert code==200 and ('fixture-'+role).encode() in body,(role,code)
  # 成员饮食照片走 users_sensitive（仅 super_admin/operator，见 index.php photo
  # 处理器注释与 requireAdminWrite('member_photo')）；旧矩阵 photo:role!='content'
  # 是收紧前的语义，已按现行权限更新。其余端点仍按页面权限矩阵。
  allowed={'photo':role in ('super_admin','operator'),'reward_photo':role!='support','catalog_photo':role!='support','ai_live':role not in ['support','content']}
  for endpoint in endpoints:
   page=urllib.parse.parse_qs(endpoint[1:])['p'][0];expected=200 if allowed[page] else 403
   before=Stats.count;code,body,content=get(opener,base+endpoint)
   assert code==expected,(role,page,code,expected,body[:100]);checks+=1
   if expected==200 and page!='ai_live':assert content=='image/jpeg' and body[:2]==b'\xff\xd8',(role,page,'not an image')
   if page=='ai_live':assert Stats.count-before==(1 if expected==200 else 0),'unauthorized upstream call'
 print(f'PASS {checks} Admin HTTP role/media checks; unauthorized realtime requests never reached upstream')
finally:
 web.terminate();web.wait(timeout=5);log.close();stub.shutdown();stub.server_close();router.unlink(missing_ok=True)
