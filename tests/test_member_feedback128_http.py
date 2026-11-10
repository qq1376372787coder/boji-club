"""Run only against the disposable loopback feedback128 fixture, never production."""
import concurrent.futures,struct,hashlib,http.cookiejar,json,os,re,unittest,urllib.error,urllib.parse,urllib.request,uuid
from pathlib import Path
BASE=os.environ.get('BOJI_FEEDBACK128_TEST_BASE','http://127.0.0.1:18928')
if urllib.parse.urlparse(BASE).hostname not in ('127.0.0.1','localhost'):raise RuntimeError('isolated loopback only')
ROOT=Path(os.environ.get('BOJI_FEEDBACK128_FIXTURES','/opt/boji-indep128'))
A='feedback128-a-'+'a'*48;B='feedback128-b-'+'b'*48

def req(path,method='GET',body=None,token=A,mime='application/json',headers=None,opener=None):
 data=json.dumps(body).encode() if isinstance(body,dict) else body
 h={'Content-Type':mime}
 if token:h['Authorization']='Bearer '+token
 h.update(headers or {})
 try:r=(opener.open if opener else urllib.request.urlopen)(urllib.request.Request(BASE+path,data=data,method=method,headers=h),timeout=40)
 except urllib.error.HTTPError as e:r=e
 raw=r.read();value=json.loads(raw) if r.headers.get_content_type()=='application/json' else raw
 return r.status,value,r.headers

def uid():return str(uuid.uuid4())
def upload(data,mime='image/jpeg',token=A,ident=None):
 ident=ident or uid();s,b,_=req('/account/v1/me/feedback/attachments/'+ident,'PUT',data,token,mime,{'X-Content-SHA256':hashlib.sha256(data).hexdigest()});return ident,s,b

def submit(ident=None,attachments=None,text='合成反馈：输入框遮挡，请核对。'):
 ident=ident or uid();body={'client_id':ident,'category':'problem','text':text,'attachments':attachments or [],'metadata':{'build':'128','app_version':'0.15.6','os_version':'fixture','device_family':'iPhone'}}
 s,b,_=req('/account/v1/me/feedback/'+ident,'POST',body);return ident,body,s,b

class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*a,**kw):return None
class FeedbackHTTP128(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.jpg=(ROOT/'fixture.jpg').read_bytes();cls.video=(ROOT/'fixture.mp4').read_bytes()
 def test_01_authentication_required(self):self.assertEqual(req('/account/v1/me/feedback',token=None)[0],401)
 def test_02_text_submission_duplicate_and_payload_binding(self):
  ident,body,s,b=submit();self.assertEqual(s,200,b);self.assertEqual(len(b['messages']),1)
  self.assertEqual(req('/account/v1/me/feedback/'+ident,'POST',body)[1]['messages'][0]['id'],b['messages'][0]['id'])
  body['text']='不同内容';self.assertEqual(req('/account/v1/me/feedback/'+ident,'POST',body)[0],409)
  self.assertEqual(req('/account/v1/me/feedback/'+ident,token=B)[0],404)
  self.assertEqual(req('/account/v1/me/feedback/'+ident+'/read','POST',{'message_id':1},token=B)[0],404)
 def test_03_picture_private_and_reencoding(self):
  media,s,b=upload(self.jpg);self.assertEqual(s,200,b)
  self.assertEqual(upload(self.jpg,ident=media)[1],200)
  self.assertEqual(upload(self.jpg+b'changed',ident=media)[1],409)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media)[0],404)
  ticket,_,s,b=submit(attachments=[media]);self.assertEqual(s,200,b)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,token=B)[0],404)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,token=None)[0],401)
  code,picture,h=req('/account/v1/me/feedback/attachments/'+media);self.assertEqual(code,200);self.assertEqual(h.get_content_type(),'image/jpeg');self.assertTrue(picture.startswith(b'\xff\xd8'))
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,'DELETE')[0],409)
  self.assertEqual(submit(attachments=[media])[2],409)
 def test_04_video_and_ranges(self):
  media,s,b=upload(self.video,'video/mp4');self.assertEqual(s,200,b);self.assertEqual(b['attachment']['kind'],'video')
  self.assertLess(b['attachment']['duration_seconds'],61)
  ticket,_,s,b=submit(attachments=[media]);self.assertEqual(s,200,b)
  s,raw,h=req('/account/v1/me/feedback/attachments/'+media,headers={'Range':'bytes=0-19'});self.assertEqual(s,206);self.assertEqual(len(raw),20);self.assertTrue(h['Content-Range'].startswith('bytes 0-19/'))
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,headers={'Range':'bytes=99999999-'})[0],416)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,headers={'Range':'bytes=0-2,10-12'})[0],416)
  padded=self.video+struct.pack('>I4s',19*1024*1024,b'free')+b'\0'*(19*1024*1024-8)
  self.assertEqual(upload(padded,'video/mp4')[1],200)
 def test_05_attachment_spoof_hash_duration_and_owner(self):
  self.assertEqual(upload(b'<script>'+b'x'*100,'video/mp4')[1],422)
  self.assertEqual(upload(self.jpg,'video/mp4')[1],422)
  self.assertEqual(upload((ROOT/'long.mp4').read_bytes(),'video/mp4')[1],422)
  media=uid();self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,'PUT',self.jpg,mime='image/jpeg',headers={'X-Content-SHA256':'0'*64})[0],422)
  media,s,_=upload(self.jpg,token=B);self.assertEqual(s,200)
  self.assertEqual(submit(attachments=[media])[2],409)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,'DELETE')[0],200)
  own_ticket=uid();self.assertEqual(req('/account/v1/me/feedback/'+own_ticket,'POST',{'client_id':own_ticket,'text':'B retained attachment','attachments':[media]},token=B)[0],200)
  self.assertEqual(req('/account/v1/me/feedback/attachments/'+media,'DELETE',token=B)[0],409)
 def test_06_validation_and_concurrent_duplicate(self):
  self.assertEqual(submit(text='')[2],422);self.assertEqual(submit(text='长'*4001)[2],422)
  ident=uid();body={'client_id':ident,'text':'并发同一条合成反馈','attachments':[]}
  with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:rows=list(ex.map(lambda _:req('/account/v1/me/feedback/'+ident,'POST',body),range(2)))
  self.assertEqual([r[0] for r in rows],[200,200]);self.assertEqual(rows[0][1]['messages'][0]['id'],rows[1][1]['messages'][0]['id'])
 def admin(self,role):
  op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),NoRedirect())
  s,b,h=req('/admin/?p=login',token=None,opener=op);self.assertEqual(s,200)
  csrf=re.search(rb'name="csrf" value="([a-f0-9]+)"',b).group(1).decode()
  body=urllib.parse.urlencode({'csrf':csrf,'action':'login','username':'fixture-'+role,'password':'fixture-password128'}).encode()
  self.assertEqual(req('/admin/', 'POST',body,None,'application/x-www-form-urlencoded',opener=op)[0],303)
  return op
 def test_07_admin_reply_and_member_unread_read_followup(self):
  image,status,_=upload(self.jpg);self.assertEqual(status,200)
  ident,body,s,b=submit(text='测试管理员回复闭环 <script>alert(1)</script>',attachments=[image]);self.assertEqual(s,200)
  op=self.admin('support');s,page,_=req('/admin/?p=feedback&ticket='+ident,token=None,opener=op);self.assertEqual(s,200);self.assertIn('测试管理员回复闭环'.encode(),page)
  self.assertNotIn(b'<script>alert(1)</script>',page);self.assertIn(b'&lt;script&gt;',page)
  self.assertEqual(req('/admin/?p=feedback_media&id='+image,token=None,opener=op)[0],200)
  csrf=re.search(rb'name="csrf" value="([a-f0-9]+)"',page).group(1).decode();reply=uid()
  form={'csrf':csrf,'action':'feedback_reply','ticket_id':ident,'client_id':reply,'last_message_id':b['ticket']['last_message_id'],'text':'合成客服回复：请升级后重试。'}
  post=lambda x:req('/admin/?p=feedback&ticket='+ident,'POST',urllib.parse.urlencode(x).encode(),None,'application/x-www-form-urlencoded',opener=op)
  self.assertEqual(post(form)[0],303);self.assertEqual(post(form)[0],303)
  s,d,_=req('/account/v1/me/feedback/'+ident);self.assertEqual(len(d['messages']),2);self.assertTrue(d['ticket']['unread']);self.assertEqual(d['messages'][-1]['text'],form['text'])
  self.assertEqual(req('/account/v1/me/feedback/'+ident+'/read','POST',{'message_id':d['ticket']['last_message_id']})[0],200)
  self.assertFalse(req('/account/v1/me/feedback/'+ident)[1]['ticket']['unread'])
  self.assertEqual(req('/account/v1/me/feedback/'+ident+'/messages','POST',{'client_id':uid(),'text':'又补充了一条','attachments':[]})[0],200)
  form['client_id']=uid();s,page,_=post(form);self.assertEqual(s,200);self.assertIn('用户已有新消息'.encode(),page)
  self.assertEqual(len(req('/account/v1/me/feedback/'+ident)[1]['messages']),3)
  form.pop('client_id');form.update(action='feedback_status',status='closed',last_message_id=req('/account/v1/me/feedback/'+ident)[1]['ticket']['last_message_id']);self.assertEqual(post(form)[0],303)
  self.assertEqual(req('/account/v1/me/feedback/'+ident)[1]['ticket']['status'],'closed')
  self.assertEqual(req('/account/v1/me/feedback/'+ident+'/messages','POST',{'client_id':uid(),'text':'仍然有问题，请继续跟进'})[1]['ticket']['status'],'open')
  bad=dict(form,csrf='invalid');self.assertEqual(post(bad)[0],403)
 def test_08_admin_role_isolation(self):
  ident,_,s,d=submit();self.assertEqual(s,200)
  for role,expected in [('readonly',200),('content',403)]:
   op=self.admin(role);s,page,_=req('/admin/?p=feedback&ticket='+ident,token=None,opener=op);self.assertEqual(s,expected)
   if role=='readonly':
    self.assertNotIn(b'value="feedback_reply"',page)
    csrf=re.search(rb'name="csrf" value="([a-f0-9]+)"',page).group(1).decode()
    s,_,_=req('/admin/?p=feedback&ticket='+ident,'POST',urllib.parse.urlencode({'csrf':csrf,'action':'feedback_reply','ticket_id':ident,'client_id':uid(),'text':'forbidden'}).encode(),None,'application/x-www-form-urlencoded',opener=op);self.assertEqual(s,403)
  self.assertEqual(req('/admin/?p=feedback_media&id='+uid(),token=None)[0],403)
if __name__=='__main__':unittest.main(verbosity=2)
