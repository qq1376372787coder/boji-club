"""Execute the production image route on localhost with auth/DB fixtures, never live data."""
from pathlib import Path
import base64,hashlib,json,os,socket,subprocess,sys,tempfile,time,urllib.request,urllib.error

root=Path(sys.argv[1]).resolve()
source=(root/'account-server/public/index.php').read_text('utf-8')
start=source.index("    if ($method === 'GET' && preg_match('#^/club/rewards/(\\d+)/(image|image-info)$#'")
end=source.index("    if ($method === 'POST'",start)
route=source[start:end]
functions=source[source.index('function respond('):source.index('function body(')]
checks=0
def check(value,label):
    global checks
    if not value: raise AssertionError(label)
    checks+=1

with tempfile.TemporaryDirectory(prefix='boji-v23-http-') as temp:
    folder=Path(temp);(folder/'admin-media').mkdir();(folder/'public').mkdir()
    helper=(root/'account-server/public/club-artwork.php').read_text('utf-8')
    (folder/'public/club-artwork.php').write_text(helper,'utf-8')
    name='club-keepsake-01-test-v20.png'
    data=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1sAAAAASUVORK5CYII=')
    image=folder/'admin-media'/name;image.write_bytes(data)
    auth=r'''
function authenticated($db): array {
    if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== 'Bearer isolated-test') fail('no auth',401);
    return ['id'=>7];
}
class StatementFixture {
    private array $params=[];
    function execute(array $params): void { $this->params=$params; }
    function fetchColumn() { return $this->params === [1,7] ? 'club-keepsake-01-test-v20.png' : false; }
}
class DBFixture { function prepare(string $query): StatementFixture { return new StatementFixture(); } }
$db=new DBFixture();$method=$_SERVER['REQUEST_METHOD'];$path=parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH);
'''
    router='<?php\n'+functions+"require __DIR__.'/public/club-artwork.php';\n"+auth+route+"fail('no route',404);\n"
    (folder/'router.php').write_text(router,'utf-8')
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    log=open(folder/'http.log','wb')
    process=subprocess.Popen(['php','-S',f'127.0.0.1:{port}',str(folder/'router.php')],cwd=folder,stdout=log,stderr=log)
    def request(path,auth=True,headers=None):
        fields=dict(headers or {})
        if auth: fields['Authorization']='Bearer isolated-test'
        req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers=fields)
        try:
            with urllib.request.urlopen(req,timeout=5) as response:return response.status,dict(response.headers),response.read()
        except urllib.error.HTTPError as error:return error.code,dict(error.headers),error.read()
    try:
        for attempt in range(50):
            try: request('/ready',False);break
            except urllib.error.URLError:time.sleep(.1)
        check(request('/club/rewards/1/image',False)[0]==401,'image needs auth')
        check(request('/club/rewards/1/image-info',False)[0]==401,'metadata needs auth')
        check(request('/club/rewards/2/image-info')[0]==404,'unavailable reward has no metadata')
        status,headers,raw=request('/club/rewards/1/image-info');meta=json.loads(raw)
        check(status==200 and meta['image_sha256']==hashlib.sha256(data).hexdigest(),'route returns real content metadata')
        status,headers,raw=request('/club/rewards/1/image?version='+meta['image_version'])
        check(status==200 and raw==data,'current version serves complete image bytes')
        check(headers['X-Content-SHA256']==hashlib.sha256(raw).hexdigest(),'download header agrees with content hash')
        check(headers['Cache-Control']=='private,no-store','authenticated image does not enter shared browser cache')
        check(request('/club/rewards/1/image',headers={'If-None-Match':headers['ETag']})[0]==304,'matching entity returns no duplicate content')
        check(request('/club/rewards/1/image?version='+('0'*64))[0]==409,'stale request is rejected rather than miscached')
        check(request('/club/rewards/1/image?version[]=bad')[0]==409,'array query parameter safely rejected')
        check(request('/club/rewards/1/image')[0]==200,'old app without version remains compatible')
        original_time=image.stat().st_mtime;image.write_bytes(data+b'new-content');os.utime(image,(original_time,original_time))
        changed=json.loads(request('/club/rewards/1/image-info')[2])
        check(changed['image_version']!=meta['image_version'],'same name and timestamp updates across HTTP requests')
        check(request('/club/rewards/1/image?version='+meta['image_version'])[0]==409,'previous cached version cannot claim new content')
        print(f'PASS {checks} v23 isolated production HTTP route checks')
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        log.close()
