<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/apple-key-cache.php';
require __DIR__.'/../account-server/public/apple-auth.php';
require __DIR__.'/../account-server/public/media-quota.php';
require __DIR__.'/../account-server/public/ai-response.php';
function check48(bool $ok,string $name):void { if(!$ok)throw new RuntimeException($name);echo 'PASS '.$name.PHP_EOL; }
function rejects48(callable $fn,string $name):void {try{$fn();}catch(Throwable){check48(true,$name);return;}throw new RuntimeException($name);}
$temporary = sys_get_temp_dir().'/bojiclub-keys-test-'.bin2hex(random_bytes(8));
mkdir($temporary,0700);
$key=['kid'=>'test-key','kty'=>'RSA','n'=>'somerandommodulus','e'=>'AQAB'];$calls=0;
$fetch=function()use(&$calls,$key){$calls++;return json_encode(['keys'=>[$key]],JSON_THROW_ON_ERROR);};
try{
    check48(cachedAppleKeys($temporary,'test-key',$fetch,1000)[0]['kid']==='test-key','first key fetch');
    cachedAppleKeys($temporary,'test-key',$fetch,1100);check48($calls===1,'fresh known key uses cache');
    rejects48(fn()=>cachedAppleKeys($temporary,'../../bad',$fetch,1200),'invalid kid does not fetch');
    rejects48(fn()=>cachedAppleKeys($temporary,'new-key',$fetch,1200),'unknown kid rejected after refresh');
    check48($calls===2,'unknown kid refresh occurs once');
    rejects48(fn()=>cachedAppleKeys($temporary,'new-key',$fetch,1201),'unknown kid refresh throttled');
    check48($calls===2,'throttle prevents network hammering');
    cachedAppleKeys($temporary,'test-key',$fetch,1202);check48($calls===2,'known key works during probe backoff');
    $badFetch=fn()=>throw new RuntimeException('network down');
    rejects48(fn()=>cachedAppleKeys($temporary,'test-key',$badFetch,5000),'expired keys fail closed on network error');
    rejects48(fn()=>cachedAppleKeys($temporary,'test-key',$fetch,5001),'failed refresh has backoff');
    cachedAppleKeys($temporary,'test-key',$fetch,5031);check48($calls===3,'retry succeeds after backoff');
}finally{foreach(glob($temporary.'/*') as $file)unlink($file);rmdir($temporary);}

check48(mediaQuotaProblem(100,1,0,200,0,['media_storage_limit_bytes'=>4194304])===null,'new upload within quota');
check48(mediaQuotaProblem(4194300,1,0,200,0,['media_storage_limit_bytes'=>4194304])['status']===413,'total bytes bounded');
check48(mediaQuotaProblem(4194300,1,4194300,200,0,['media_storage_limit_bytes'=>4194304])===null,'replacement accounts for prior bytes');
check48(mediaQuotaProblem(100,2,0,200,0,['media_file_limit'=>2])['status']===413,'new file count bounded');
check48(mediaQuotaProblem(100,2,100,200,0,['media_file_limit'=>2])===null,'replacement permitted at file count limit');
check48(mediaQuotaProblem(100,1,0,200,120)['status']===429,'upload burst limited');
$value=publicAIResponse(['id'=>'job','status'=>'succeeded','result'=>['summary'=>'正常分析'],'trace'=>'secret','request'=>['token'=>'secret']]);
check48(!isset($value['trace'],$value['request']) && $value['result']['summary']==='正常分析','proxy keeps required output and drops internal fields');
check48(publicAIResponse(['error'=>'Traceback internal secret'])['error']!=='Traceback internal secret','trace error filtered');
check48(publicAIResponse(['retry_started'=>false])['retry_started']===false,'retry no-op flag preserved');
check48(publicAIResponse(['error'=>'会员暂未生效'])['error']==='会员暂未生效','safe actionable error preserved');
// Real signature verification remains active after introducing the cache.
$private=openssl_pkey_new(['private_key_bits'=>2048,'private_key_type'=>OPENSSL_KEYTYPE_RSA]);
$detail=openssl_pkey_get_details($private);$b64=fn($x)=>rtrim(strtr(base64_encode($x),'+/','-_'),'=');
$jwk=['kid'=>'signed','kty'=>'RSA','n'=>$b64($detail['rsa']['n']),'e'=>$b64($detail['rsa']['e'])];
$nonce=str_repeat('a',64);$claims=['iss'=>'https://appleid.apple.com','aud'=>'com.bojiclub.app.dev','sub'=>'test-sub','nonce'=>$nonce,'iat'=>1000,'exp'=>2000];
$head=$b64(json_encode(['alg'=>'RS256','kid'=>'signed']));$body=$b64(json_encode($claims));
openssl_sign($head.'.'.$body,$signature,$private,OPENSSL_ALGO_SHA256);$token=$head.'.'.$body.'.'.$b64($signature);
check48(verifyAppleIdentity($token,$nonce,['com.bojiclub.app.dev'],[$jwk],1100)==='test-sub','valid Apple signature accepted');
rejects48(fn()=>verifyAppleIdentity($token,str_repeat('b',64),['com.bojiclub.app.dev'],[$jwk],1100),'nonce remains checked');
rejects48(fn()=>verifyAppleIdentity($token,$nonce,['other-app'],[$jwk],1100),'audience remains checked');
rejects48(fn()=>verifyAppleIdentity($token,$nonce,['com.bojiclub.app.dev'],[$jwk],2100),'expiry remains checked');
echo 'ALL V48 PHP RULES PASSED'.PHP_EOL;
