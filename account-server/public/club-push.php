<?php
declare(strict_types=1);
function clubPushActivationTime(string $raw): string {
    $date=DateTimeImmutable::createFromFormat('!Y-m-d H:i:s',$raw,new DateTimeZone('UTC'));
    if(!$date||$date->format('Y-m-d H:i:s')!==$raw)throw new RuntimeException('PUSH_ACTIVATION_TIME_REQUIRED');
    return $raw;
}
function clubPushCreatedSince(string $deviceSince,string $activation): string {
    return max(clubPushActivationTime($deviceSince),clubPushActivationTime($activation));
}
function clubPushConfigured(array $c): bool {
    return ($c['apns_enabled']??false)===true && preg_match('/^[A-Z0-9]{10}$/D',$c['apns_key_id']??'')===1 && preg_match('/^[A-Z0-9]{10}$/D',$c['apns_team_id']??'')===1 && is_file($c['apns_key_path']??'') && ($c['apns_topic']??'')==='com.bojiclub.app.dev';
}
function clubPushTransportReady(): bool {return function_exists('curl_init')&&defined('CURL_VERSION_HTTP2')&&(curl_version()['features']&CURL_VERSION_HTTP2)!==0;}
function clubPushBase64(string $s): string {return rtrim(strtr(base64_encode($s),'+/','-_'),'=');}
function clubPushRawSignature(string $der): string {
    $i=0;$length=strlen($der);
    $take=function(int $expected)use(&$i,$der,$length):int {
        if($i>=$length || ord($der[$i++])!==$expected)throw new RuntimeException('invalid signature');
        if($i>=$length)throw new RuntimeException('invalid signature');$n=ord($der[$i++]);
        if($n&128){$count=$n&127;if($count>2||$i+$count>$length)throw new RuntimeException('invalid signature');$n=0;while($count--)$n=($n<<8)|ord($der[$i++]);}
        return $n;
    };
    $total=$take(48);if($i+$total!==$length)throw new RuntimeException('invalid signature');$parts=[];
    for($n=0;$n<2;$n++){$bytes=$take(2);if($bytes<1||$i+$bytes>$length)throw new RuntimeException('invalid signature');$p=ltrim(substr($der,$i,$bytes),"\0");$i+=$bytes;if(strlen($p)>32)throw new RuntimeException('invalid signature');$parts[]=str_pad($p,32,"\0",STR_PAD_LEFT);}
    if($i!==$length)throw new RuntimeException('invalid signature');return implode('',$parts);
}
function clubPushJWT(array $c,?int $now=null): string {
    $now??=time();if(!clubPushConfigured($c))throw new RuntimeException('push not configured');
    $directory=$c['apns_cache_directory']??dirname(__DIR__).'/private-cache';
    if(!is_dir($directory)&&!mkdir($directory,0700,true))throw new RuntimeException('push cache unavailable');
    $old=umask(0077);$file=fopen($directory.'/apns-'.hash('sha256',$c['apns_key_id'].':'.filemtime($c['apns_key_path'])).'.json','c+');umask($old);
    if(!$file||!flock($file,LOCK_EX))throw new RuntimeException('push cache unavailable');
    try {
        $cached=json_decode(stream_get_contents($file),true);
        if(is_array($cached)&&isset($cached['token'],$cached['created'])&&$cached['created']<=$now&&$now-$cached['created']<3000)return $cached['token'];
        $key=openssl_pkey_get_private(file_get_contents($c['apns_key_path']));$details=$key?openssl_pkey_get_details($key):false;
        if(!$details||($details['ec']['curve_name']??'')!=='prime256v1')throw new RuntimeException('invalid push signing key');
        $content=clubPushBase64(json_encode(['alg'=>'ES256','kid'=>$c['apns_key_id']],JSON_THROW_ON_ERROR)).'.'.clubPushBase64(json_encode(['iss'=>$c['apns_team_id'],'iat'=>$now],JSON_THROW_ON_ERROR));
        if(!openssl_sign($content,$signature,$key,OPENSSL_ALGO_SHA256))throw new RuntimeException('push signing unavailable');
        $token=$content.'.'.clubPushBase64(clubPushRawSignature($signature));
        rewind($file);ftruncate($file,0);fwrite($file,json_encode(['created'=>$now,'token'=>$token],JSON_THROW_ON_ERROR));fflush($file);return $token;
    }finally{flock($file,LOCK_UN);fclose($file);}
}
function clubPushAllowed(array $p,string $kind,?int $now=null): ?int {
    $now??=time();$weekly=in_array($kind,['weekly_review','club_weekly'],true);
    if(!($p[$weekly?'weekly':'daily']??false))return null;
    $date=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone($p['zone']));$hour=(int)$date->format('G');$start=$p['quiet_start'];$end=$p['quiet_end'];
    $quiet=$start<$end?($hour>=$start&&$hour<$end):($hour>=$start||$hour<$end);
    if(!($p['quiet']??false)||!$quiet)return $now;
    $next=$date->setTime($end,0);if($next->getTimestamp()<=$now)$next=$next->modify('+1 day');return $next->getTimestamp();
}
function clubPushProactiveLimitValue(int $value): int {return $value<0?0:($value>20?20:$value);}
function clubPushBudgetClass(string $kind): string {
    // 训练/餐次提醒为用户预设提醒(reminder)；报告与周复盘为分析通知(report)；账户安全走(account)；其余为主动关怀(proactive)。
    // 各自走各自设置开关，非 proactive 类不占普通每日主动预算。
    if (in_array($kind, ['report', 'weekly_review'], true)) {
        return 'report';
    }
    if (in_array($kind, ['training_reminder', 'meal_reminder'], true)) {
        return 'reminder';
    }
    if (in_array($kind, ['account', 'security'], true)) {
        return 'account';
    }
    return 'proactive';
}
function clubPushBudgetDay(?int $now=null): string {
    // 预算日按后台统计时区（北京时间）计算，与 AI 每日额度口径一致。
    $now??=time();
    return (new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone('Asia/Shanghai'))->format('Y-m-d');
}
function clubPushSemanticKey(string $kind,string $date,string $clientJobId): string {
    // 语义组＝kind/日期/任务三个维度；同组一天至多一条，多设备共用同一预约。
    return hash('sha256',strtolower($kind).'|'.$date.'|'.strtolower($clientJobId));
}
function clubPushProactiveDailyLimit(PDO $db): int {
    $q=$db->query("SELECT setting_value FROM club_push_settings WHERE setting_key='proactive_daily_limit'");
    $raw=$q->fetchColumn();
    return clubPushProactiveLimitValue($raw===false?1:(int)$raw);
}
function clubPushBudgetDecision(?array $existing,string $deviceId,string $class,int $used,int $limit): string {
    // 纯决策：'send' 允许发送（复用或新建预约）；'duplicate' 同语义组今日已有设备负责；'budget' 账号今日普通主动预算已用完。
    if(is_array($existing)) {
        $status=(string)($existing['status']??'');
        if($status==='failed')return 'send'; // 首发失败后允许接管重发，沿用同一预约，不重复扣预算
        return (string)($existing['device_id']??'')===$deviceId?'send':'duplicate'; // 同设备网络重试复用原预约
    }
    if($class==='proactive'&&$used>=$limit)return 'budget';
    return 'send';
}
function clubPushReserve(PDO $db,int $userId,string $deviceId,string $clientJobId,string $kind,string $date): array {
    // 发送前在账号级预约预算与语义组：同一事务、幂等；APNs 网络重试复用原预约，不重复扣预算。
    $day=clubPushBudgetDay();$semantic=clubPushSemanticKey($kind,$date,$clientJobId);$class=clubPushBudgetClass($kind);
    $decision='budget';
    $db->beginTransaction();
    try {
        $q=$db->prepare('SELECT status,device_id FROM club_push_budget WHERE user_id=? AND budget_day=? AND semantic_key=? FOR UPDATE');
        $q->execute([$userId,$day,$semantic]);$row=$q->fetch();
        $existing=is_array($row)?['status'=>(string)$row['status'],'device_id'=>(string)$row['device_id']]:null;
        $used=0;
        if($class==='proactive'&&$existing===null) {
            $q=$db->prepare("SELECT COUNT(*) FROM club_push_budget WHERE user_id=? AND budget_day=? AND budget_class='proactive' AND status IN ('reserved','sent')");
            $q->execute([$userId,$day]);$used=(int)$q->fetchColumn();
        }
        $limit=$class==='proactive'?clubPushProactiveDailyLimit($db):0;
        $decision=clubPushBudgetDecision($existing,$deviceId,$class,$used,$limit);
        if($decision==='send'&&($existing===null||$existing['status']==='failed')) {
            $db->prepare("INSERT INTO club_push_budget(user_id,budget_day,semantic_key,kind,budget_class,status,device_id,client_job_id,created_at,updated_at) VALUES(?,?,?,?,?,'reserved',?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status='reserved',device_id=VALUES(device_id),client_job_id=VALUES(client_job_id),updated_at=UTC_TIMESTAMP()")
                ->execute([$userId,$day,$semantic,$kind,$class,$deviceId,$clientJobId]);
        }
        $db->commit();
    }catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
    return ['decision'=>$decision,'day'=>$day,'semantic'=>$semantic,'class'=>$class];
}
function clubPushReservationFinish(PDO $db,int $userId,array $reservation,string $status): void {
    // 发送终态回写预约：sent=已送达；failed=首发终态失败（允许接管，不再自动重试）。退避重试期间保持 reserved。
    if(!in_array($status,['sent','failed'],true))return;
    $db->prepare('UPDATE club_push_budget SET status=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND budget_day=? AND semantic_key=?')
        ->execute([$status,$userId,$reservation['day'],$reservation['semantic']]);
}
function clubPushAccountBlocked(PDO $db,int $userId): bool {
    $q=$db->prepare('SELECT 1 FROM club_push_account_blocks WHERE user_id=?');$q->execute([$userId]);
    return (bool)$q->fetchColumn();
}
function clubPushSendContent(array $c,array $device,array $payload,string $collapseId,?callable $transport=null): array {
    $jwt=clubPushJWT($c);$host=$device['environment']==='production'?'api.push.apple.com':'api.sandbox.push.apple.com';
    if(!preg_match('/^[a-f0-9]{2,1024}$/D',$device['token']) || strlen($device['token'])%2)throw new RuntimeException('invalid token');
    $headers=['authorization: bearer '.$jwt,'apns-topic: '.$c['apns_topic'],'apns-push-type: alert','apns-priority: 10','apns-expiration: '.(time()+86400),'apns-collapse-id: '.$collapseId,'content-type: application/json'];
    $url='https://'.$host.'/3/device/'.$device['token'];$body=json_encode($payload,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
    if($transport)return $transport($url,$headers,$body);
    if(!clubPushTransportReady())throw new RuntimeException('push transport unavailable');
    $curl=curl_init($url);curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>$body,CURLOPT_HTTPHEADER=>$headers,CURLOPT_HTTP_VERSION=>CURL_HTTP_VERSION_2_0,CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>10]);
    $raw=curl_exec($curl);$status=(int)curl_getinfo($curl,CURLINFO_RESPONSE_CODE);curl_close($curl);
    $reason=json_decode($raw===false?'':$raw,true)['reason']??'NetworkError';
    return ['status'=>$status,'reason'=>is_string($reason)&&preg_match('/^[A-Za-z0-9]{1,80}$/D',$reason)?$reason:'UnknownError'];
}
function clubPushSend(array $c,array $device,array $event,?callable $transport=null): array {
    $payload=['aps'=>['alert'=>['title'=>'Club AI 的新跟进已准备好','body'=>'打开薄肌俱乐部，查看已保存的分析。'],'sound'=>'default','thread-id'=>'club-ai'],
        'boji_kind'=>$event['kind'],'boji_date'=>$event['date'],'boji_account'=>(int)$device['user_id'],'boji_job'=>$event['client_job_id']];
    return clubPushSendContent($c,$device,$payload,hash('sha256',$device['device_id'].'/'.$event['client_job_id']),$transport);
}
function clubPushRoutes(PDO $db,array $c,string $method,string $path): void {
    if($path!=='/me/push-device')return;
    if($method!=='PUT')fail('不支持此操作。',405);$user=authenticated($db);$value=body(8192);
    if(!is_string($value['device_id']??null)||!is_array($value['preferences']??null))fail('手机通知登记格式不正确。');
    $id=strtolower($value['device_id']);$env=$value['environment']??'';$p=$value['preferences'];
    if(!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$id))fail('手机通知登记格式不正确。');
    if(($p['enabled']??null)===false){
        $db->prepare('UPDATE club_push_devices SET enabled=0 WHERE device_id=? AND user_id=?')->execute([$id,(int)$user['id']]);
        $db->prepare("UPDATE club_push_receipts r JOIN club_push_devices d ON d.device_id=r.device_id SET r.status='skipped' WHERE r.device_id=? AND d.user_id=? AND r.status='pending'")->execute([$id,(int)$user['id']]);
        respond(200,['push_ready'=>false]);
    }
    if(!is_string($value['token']??null))fail('手机通知登记格式不正确。');$token=strtolower($value['token']);
    if(!preg_match('/^[a-f0-9]{2,1024}$/D',$token)||strlen($token)%2||!in_array($env,['development','production'],true))fail('手机通知登记格式不正确。');
    foreach(['enabled','daily','weekly','quiet'] as $flag)if(!is_bool($p[$flag]??null))fail('手机通知设置不正确。');
    foreach(['quiet_start','quiet_end'] as $field)if(!is_int($p[$field]??null)||$p[$field]<0||$p[$field]>23)fail('免打扰时段不正确。');
    if($p['quiet_start']===$p['quiet_end'])fail('免打扰时段不正确。');
    if(!is_string($p['zone']??null)||strlen($p['zone'])>100)fail('手机时区不正确。');
    try{new DateTimeZone($p['zone']);}catch(Exception){fail('手机时区不正确。');}
    $p=array_intersect_key($p,array_flip(['enabled','daily','weekly','quiet','quiet_start','quiet_end','zone']));
    $db->beginTransaction();lockActiveUser($db,(int)$user['id']);
    $db->prepare('DELETE FROM club_push_devices WHERE token=? AND device_id<>?')->execute([$token,$id]);
    // Rebinding a device clears receipts owned by the previous account.
    $q=$db->prepare('SELECT user_id FROM club_push_devices WHERE device_id=? FOR UPDATE');$q->execute([$id]);$previous=$q->fetchColumn();
    if($previous && (int)$previous!==(int)$user['id'])$db->prepare('DELETE FROM club_push_receipts WHERE device_id=?')->execute([$id]);
    $db->prepare('INSERT INTO club_push_devices(device_id,user_id,session_hash,token,environment,enabled,preferences_json,notify_after,next_check,updated_at) VALUES(?,?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE notify_after=IF(enabled=0 OR user_id<>VALUES(user_id),UTC_TIMESTAMP(),notify_after),user_id=VALUES(user_id),session_hash=VALUES(session_hash),token=VALUES(token),environment=VALUES(environment),enabled=VALUES(enabled),preferences_json=VALUES(preferences_json),updated_at=UTC_TIMESTAMP()')
        ->execute([$id,(int)$user['id'],$user['token_hash'],$token,$env,(int)$p['enabled'],json_encode($p,JSON_THROW_ON_ERROR)]);
    $db->prepare("UPDATE club_push_receipts SET next_attempt=UTC_TIMESTAMP() WHERE device_id=? AND status='pending'")->execute([$id]);
    $db->commit();respond(200,['push_ready'=>clubPushConfigured($c)&&clubPushTransportReady()]);
}
