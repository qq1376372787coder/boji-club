<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/club-push.php';
$checks=0;function pushCheck(bool $value,string $label):void{global $checks;if(!$value)throw new LogicException($label);$checks++;}
pushCheck(!clubPushConfigured([]),'missing keys never enable remote sends');
pushCheck(clubPushCreatedSince('2026-10-01 00:00:00','2026-10-29 01:00:00')==='2026-10-29 01:00:00','activation excludes all historical results');
pushCheck(clubPushCreatedSince('2026-10-30 00:00:00','2026-10-29 01:00:00')==='2026-10-30 00:00:00','new device opt-in remains the stricter boundary');
foreach(['','2026-02-30 00:00:00','2026-10-29T01:00:00Z'] as $invalid){try{clubPushActivationTime($invalid);throw new LogicException('invalid activation accepted');}catch(RuntimeException){pushCheck(true,'invalid or missing activation cannot backfill old messages');}}
$p=['daily'=>true,'weekly'=>true,'quiet'=>true,'quiet_start'=>22,'quiet_end'=>8,'zone'=>'Asia/Shanghai'];
$night=(new DateTimeImmutable('2026-10-15 23:00:00',new DateTimeZone('Asia/Shanghai')))->getTimestamp();
pushCheck(clubPushAllowed($p,'report',$night)===$night+9*3600,'quiet interval defers until next local morning');
$p['daily']=false;pushCheck(clubPushAllowed($p,'club_workout',$night)===null,'daily toggle also controls workout insight reminders');
pushCheck(clubPushAllowed($p,'club_weekly',$night)===$night+9*3600,'weekly toggle remains independent');
$p['quiet']=false;pushCheck(clubPushAllowed($p,'weekly_review',$night)===$night,'quiet off sends without delay');
$folder=sys_get_temp_dir().'/boji-push-test-'.bin2hex(random_bytes(8));mkdir($folder,0700);
try{
 $key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);
 if(!$key)throw new RuntimeException('test EC runtime unavailable');
 openssl_pkey_export($key,$private);$file=$folder.'/synthetic.pem';file_put_contents($file,$private);chmod($file,0600);
 $config=['apns_enabled'=>true,'apns_key_id'=>'TESTKEY001','apns_team_id'=>'GYFUN6MZ9J','apns_key_path'=>$file,'apns_topic'=>'com.bojiclub.app.dev','apns_cache_directory'=>$folder];
 $now=time();$jwt=clubPushJWT($config,$now);$parts=explode('.',$jwt);pushCheck(count($parts)===3,'ES256 token has three JWT parts');
 $decode=fn($s)=>base64_decode(strtr($s,'-_','+/'),true);
 $header=json_decode($decode($parts[0]),true);$claims=json_decode($decode($parts[1]),true);
 pushCheck($header['alg']==='ES256'&&$header['kid']==='TESTKEY001'&&$claims['iss']==='GYFUN6MZ9J'&&$claims['iat']===$now,'APNs claims are exact');
 $raw=$decode($parts[2]);pushCheck(strlen($raw)===64,'ASN.1 converted to JOSE P-256 signature');
 $integer=function($s){$s=ltrim($s,"\0");if($s==='' || (ord($s[0])&128))$s="\0".$s;return "\x02".chr(strlen($s)).$s;};
 $pair=$integer(substr($raw,0,32)).$integer(substr($raw,32));$der="\x30".chr(strlen($pair)).$pair;
 pushCheck(openssl_verify($parts[0].'.'.$parts[1],$der,openssl_pkey_get_details($key)['key'],OPENSSL_ALGO_SHA256)===1,'actual cryptographic signature verifies');
 pushCheck(clubPushJWT($config,$now+2999)===$jwt,'provider token is reused within fifty minutes');
 pushCheck(clubPushJWT($config,$now+3001)!==$jwt,'expired provider token is replaced');
 $device=['device_id'=>'11111111-1111-1111-1111-111111111111','user_id'=>1,'environment'=>'production','token'=>str_repeat('ab',32)];
 $event=['kind'=>'club_workout','date'=>'2026-10-15','client_job_id'=>'22222222-2222-2222-2222-222222222222'];
 foreach(['production','development'] as $env){
  $device['environment']=$env;
  $result=clubPushSend($config,$device,$event,function($url,$headers,$body)use($env){
   pushCheck(str_contains($url,$env==='production'?'api.push.apple.com':'api.sandbox.push.apple.com'),'correct APNs environment host');
   pushCheck(in_array('apns-topic: com.bojiclub.app.dev',$headers,true)&&in_array('apns-push-type: alert',$headers,true),'APNs headers explicitly identify app and push type');
   $payload=json_decode($body,true);pushCheck($payload['boji_account']===1&&$payload['boji_job']==='22222222-2222-2222-2222-222222222222','notification preserves account and report destination');
   pushCheck(!str_contains($body,'weight')&&!str_contains($body,'protein')&&!str_contains($body,'answer'),'lock-screen notification contains no health or AI report details');
   return ['status'=>200,'reason'=>''];
  });pushCheck($result['status']===200,'mock transport exercises full signing path without contacting Apple');
 }
 try{clubPushRawSignature('bad');throw new LogicException('bad signature accepted');}catch(RuntimeException){pushCheck(true,'invalid DER rejected');}
}finally{foreach(glob($folder.'/*')?:[] as $path)unlink($path);rmdir($folder);}
echo "PASS {$checks} APNs crypto, privacy, routing and quiet-time checks; no real push sent\n";
