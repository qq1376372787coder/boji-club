#!/usr/bin/env python3
"""Capture real BOJI debug views in an isolated simulator; no URL routing or account-server calls."""
import argparse, hashlib, json, os, pathlib, re, subprocess, tempfile, time
p=argparse.ArgumentParser()
p.add_argument('--device',required=True,help='UDID of an already booted isolated simulator')
p.add_argument('--phase',required=True,help='baseline or candidate directory name')
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--routes',help='Comma-separated route keys; default is the complete debug harness')
p.add_argument('--accessibility',action='store_true')
p.add_argument('--variant',choices=['standard','accessibility','small','small-accessibility'],help='Output folder; accessibility font requires --accessibility')
p.add_argument('--native-shell',action='store_true',help='Capture the five real app tabs')
p.add_argument('--deny-camera',action='store_true',help='Set the isolated test simulator camera permission to denied before launch')
a=p.parse_args();project=pathlib.Path(__file__).resolve().parents[2];bundle='com.bojiclub.app.dev'
def run(args,**kw):
 r=subprocess.run(args,text=True,capture_output=True,timeout=90,**kw)
 if r.returncode: raise RuntimeError(r.stderr or r.stdout)
 return r.stdout.strip()
def sim(*args): return run(['xcrun','simctl',*args])
if a.deny_camera: sim('privacy',a.device,'revoke','camera',bundle)
out=a.output/a.phase/(a.variant or ('accessibility' if a.accessibility else 'standard'));out.mkdir(parents=True,exist_ok=True)
source=(project/'BojiClub/BojiComponentGalleryView.swift').read_text().split('struct BojiAuditHost')[1].split('enum BojiAuditFixtures')[0]
routes=a.routes.split(',') if a.routes else (['home','plans','records','profile','club-invitation'] if a.native_shell else re.findall(r'case "([\w-]+)":',source))
old_size=sim('ui',a.device,'content_size')
old_appearance=sim('ui',a.device,'appearance')
manifest=[];request=None
with tempfile.TemporaryDirectory(prefix='boji-composition-') as temp:
 ocr=pathlib.Path(temp)/'visual-text'
 run(['xcrun','swiftc',str(pathlib.Path(__file__).with_name('VisualText.swift')),'-o',str(ocr)])
 def recognize(file): return json.loads(run([str(ocr),str(file)]))[0].get('texts',[])
 env={k:v for k,v in os.environ.items() if not k.startswith('SIMCTL_CHILD_BOJI_')}
 env.update(SIMCTL_CHILD_BOJI_PREVIEW_ACCOUNT='complete',SIMCTL_CHILD_BOJI_UI_TEST_SEED='1',SIMCTL_CHILD_BOJI_PREVIEW_SKIP_GUIDE='1')
 try:
  sim('ui',a.device,'content_size','accessibility-extra-large' if a.accessibility else 'large')
  sim('ui',a.device,'appearance','light')
  sim('status_bar',a.device,'override','--time','9:41','--batteryState','charged','--batteryLevel','100','--wifiMode','active','--wifiBars','3')
  data=pathlib.Path(sim('get_app_container',a.device,bundle,'data'))/'Documents'
  request=data/'boji-audit-route.txt';ready=data/'boji-audit-ready.txt'
  request.unlink(missing_ok=True)
  if not a.native_shell:
   env['SIMCTL_CHILD_BOJI_AUDIT_SCREEN']=routes[0]
   if a.accessibility: env['SIMCTL_CHILD_BOJI_AUDIT_AX']='1'
   run(['xcrun','simctl','launch','--terminate-running-process',a.device,bundle],env=env)
   time.sleep(3)
  for route in routes:
   if a.native_shell:
    native = {'club-invitation': ('club',None), 'nutrition-in-records': ('records','饮食'), 'body-in-records': ('records','身体'), 'reports-in-records': ('records','报告')}.get(route, (route,None))
    env['SIMCTL_CHILD_BOJI_PREVIEW_TAB']=native[0]
    env.pop('SIMCTL_CHILD_BOJI_PREVIEW_RECORDS_CATEGORY',None)
    env.pop('SIMCTL_CHILD_BOJI_UI_TEST_SEED_MEALS',None)
    if native[1]:
     env['SIMCTL_CHILD_BOJI_PREVIEW_RECORDS_CATEGORY']=native[1]
     env['SIMCTL_CHILD_BOJI_UI_TEST_SEED_MEALS']='1' 
    run(['xcrun','simctl','launch','--terminate-running-process',a.device,bundle],env=env)
    time.sleep(3)
   else:
    # A different route ensures the per-screen readiness task runs even after a previous capture.
    if ready.exists() and ready.read_text()==route:
     request.write_text(('body' if route=='components' else 'components')+'|normal');time.sleep(1.5)
    ready.unlink(missing_ok=True)
    request.write_text(route+('|ax' if a.accessibility else '|normal'))
    deadline=time.monotonic()+30
    while not (ready.exists() and ready.read_text()==route):
     if time.monotonic()>deadline: raise RuntimeError('View did not report ready: '+route)
     time.sleep(.25)
    time.sleep(1.5)
   file=out/(route+'.png');texts=[]
   for attempt in range(15):
    sim('io',a.device,'screenshot',str(file));texts=recognize(file);text=' '.join(texts)
    if a.native_shell:
     rendered=sum(x in text for x in ['首页','计划','记录','俱乐部','自己'])>=4 and len(text)>60
    else: rendered=len(text)>15
    if rendered: break
    time.sleep(2)
   blocked=('访问相机' in text or '访问麦克风' in text or ('中打开' in text and '取消' in text) or (route=='home' and '使用指南' in text and '稍后再看' in text))
   row=dict(route=route,device=a.device,nativeShell=a.native_shell,rendered=rendered,systemOverlay=blocked,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),texts=texts)
   manifest.append(row);(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
   if blocked or not rendered: raise RuntimeError('Rejected capture: '+route+'; inspect simulator state before continuing')
   print(route+' captured',flush=True)
 finally:
  if request: request.unlink(missing_ok=True)
  if old_size not in ['unknown','unsupported']: sim('ui',a.device,'content_size',old_size)
  if old_appearance in ['light','dark']: sim('ui',a.device,'appearance',old_appearance)
  sim('status_bar',a.device,'clear')
