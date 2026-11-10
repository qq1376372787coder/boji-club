<?php
declare(strict_types=1);
function clubAutomationPreferences(array $input): array {
    if(($input['version']??null)!==1)throw new InvalidArgumentException('settings version');
    foreach(['enabled','daily','weekly','workout','partial'] as $key)if(!is_bool($input[$key]??null))throw new InvalidArgumentException('settings flag');
    if(!is_int($input['hour']??null)||$input['hour']<0||$input['hour']>23)throw new InvalidArgumentException('settings hour');
    if(!is_string($input['zone']??null)||strlen($input['zone'])>100)throw new InvalidArgumentException('settings zone');
    try{new DateTimeZone($input['zone']);}catch(Exception){throw new InvalidArgumentException('settings zone');}
    if(!is_int($input['enabled_at']??null)&&!is_float($input['enabled_at']??null))throw new InvalidArgumentException('settings time');
    if(!is_finite((float)$input['enabled_at'])||$input['enabled_at']<0||$input['enabled_at']>time()+60)throw new InvalidArgumentException('settings time');
    if($input['enabled'] && ($input['enabled_at']<946684800 || !($input['daily']||$input['weekly']||$input['workout'])))throw new InvalidArgumentException('settings opt-in');
    return array_intersect_key($input,array_flip(['version','enabled','daily','weekly','workout','partial','hour','zone','enabled_at']));
}
function clubAutomationPrivate(array $config,string $target,array $value): array {
    $token=$config['ai_proxy_token']??'';$base=$config['ai_proxy_base_url']??'http://127.0.0.1:8787';
    if(strlen($token)<24||!preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base))throw new RuntimeException('private service unavailable');
    $raw=json_encode($value,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
    if(strlen($raw)>5900000)throw new RuntimeException('automation context too large');
    $ctx=stream_context_create(['http'=>['method'=>'POST','header'=>"Content-Type: application/json\r\nAuthorization: Bearer ".$token."\r\n",'content'=>$raw,'timeout'=>20,'ignore_errors'=>true,'follow_location'=>0]]);
    $response=@file_get_contents($base.$target,false,$ctx);$status=502;
    foreach($http_response_header??[] as $header)if(preg_match('#^HTTP/\S+ (\d{3})#',$header,$m))$status=(int)$m[1];
    $result=$response===false?null:json_decode($response,true);
    if($status<200||$status>=300||!is_array($result))throw new RuntimeException('automatic analysis temporarily unavailable');
    return $result;
}
function clubAutomationServerID(int $uid,string $client,array $config): string {
    $hex=hash_hmac('sha256',$uid.':ai:'.$client,$config['otp_secret']);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}
function clubAutomationRetryLimit(array $config): int {
    // 同一配置版本内连续失败的上限；默认 6，允许 1—20。
    return max(1,min(20,(int)($config['automation_max_retries']??6)));
}
function clubAutomationRetryDecision(int $failures,int $limit): string {
    // 失败达到上限进入终态 failed（不再自动重试），否则按退避继续重试。
    return $failures>=$limit?'failed':'retry';
}
function clubAutomationErrorSummary(Throwable $error): string {
    // 只记录异常类型与既有英文短消息（均为内部通用文案），不含请求体、密钥或供应商原始错误。
    $message=preg_replace('/\s+/u',' ',(string)$error->getMessage())??'';
    return mb_substr(get_class($error).': '.mb_substr($message,0,60),0,100);
}
function clubAutomationCurrent(PDO $db,int $uid,int $revision): bool {
    $query=$db->prepare("SELECT 1 FROM club_automation a JOIN users u ON u.id=a.user_id AND u.status='active' WHERE a.user_id=? AND a.revision=? AND a.enabled=1 AND EXISTS(SELECT 1 FROM membership_entitlements m WHERE m.user_id=a.user_id AND m.status='active' AND m.expires_at>UTC_TIMESTAMP())");
    $query->execute([$uid,$revision]);return (bool)$query->fetchColumn();
}
function clubAutomationGoalBaseline(PDO $db,int $uid,array $state,string $first,DateTimeZone $zone): array {
    $cut=(new DateTimeImmutable($first,$zone))->getTimestamp()-978307200;$latest=null;
    $consider=function(array $goals)use(&$latest,$cut):void {
        foreach($goals as $g)if(is_array($g)&&($g['version']??null)===1&&is_numeric($g['recordedAt']??null)&&$g['recordedAt']<$cut&&isset($g['id'],$g['profile'])) {
            if($latest===null||[$g['recordedAt'],$g['id']]>[$latest['recordedAt'],$latest['id']])$latest=$g;
        }
    };
    foreach($state['days']??[] as $day)$consider($day['goalVersions']??[]);
    $q=$db->prepare("SELECT JSON_UNQUOTE(JSON_EXTRACT(state_json,'$._partitioned')) FROM app_states WHERE user_id=?");$q->execute([$uid]);
    if((string)$q->fetchColumn()==='2') {
        // Read only goal arrays from old parts, never old meals/photos/reports.
        $q=$db->prepare("SELECT JSON_EXTRACT(payload_json,'$.goalVersions') AS goals FROM cloud_parts WHERE user_id=? AND part_key LIKE 'd/%' AND date_key<? AND JSON_LENGTH(JSON_EXTRACT(payload_json,'$.goalVersions'))>0 ORDER BY date_key");$q->execute([$uid,$first]);
        while($row=$q->fetch(PDO::FETCH_ASSOC)){$goals=json_decode($row['goals'],true,32,JSON_THROW_ON_ERROR);if(is_array($goals))$consider($goals);}
    }
    return $latest===null?[]:[clubAutomationGoal($latest)];
}
function clubAutomationGoal(array $goal): array {
    $goal=array_intersect_key($goal,array_flip(['version','id','recordedAt','profile']));
    $goal['profile']=array_intersect_key($goal['profile'],array_flip(['age','height','weight','goal','experience','venue','focus','gender','limitations','daysPerWeek','trainingDays','homeTrainingDays','nutritionContext','dailyActivity','equipment','equipmentOther','sessionMinutes']));
    return $goal;
}
function clubAutomationMealFingerprint(array $meals): string {
    foreach($meals as &$meal)foreach(['photoFilename','photoRemoteID','sourceAIJobID','estimated','estimateNotes'] as $key)unset($meal[$key]);unset($meal);
    usort($meals,fn($a,$b)=>strcmp(strtolower($a['id']),strtolower($b['id'])));
    $sort=function(mixed $value)use(&$sort):mixed {
        if(!is_array($value))return $value;
        if(!array_is_list($value))ksort($value,SORT_STRING);
        foreach($value as &$child)$child=$sort($child);unset($child);return $value;
    };
    return hash('sha256',json_encode($sort($meals),JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR));
}
function clubAutomationRoutes(PDO $db,array $config,string $method,string $path): void {
    if($path!=='/me/automation')return;
    $user=authenticated($db);$uid=(int)$user['id'];
    if($method==='GET') {
        $q=$db->prepare('SELECT revision,enabled,last_status,updated_at,preferences_json FROM club_automation WHERE user_id=?');$q->execute([$uid]);$row=$q->fetch();
        respond(200,['revision'=>$row?(int)$row['revision']:0,'enabled'=>$row?(bool)$row['enabled']:false,'status'=>$row['last_status']??'not_configured','preferences'=>$row?json_decode($row['preferences_json'],true,32,JSON_THROW_ON_ERROR):null]);
    }
    if($method!=='PUT')fail('不支持此操作。',405);
    $input=body(65536);
    try{$preferences=clubAutomationPreferences($input);}catch(InvalidArgumentException){fail('自动跟进设置不正确。');}
    $revision=$input['expected_revision']??null;$cloud=$input['cloud_revision']??null;$coverage=$input['coverage']??null;
    if(!is_int($revision)||$revision<0||!is_int($cloud)||$cloud<0||!is_array($coverage)||count($coverage)>14)fail('自动跟进记录格式不正确。');
    foreach($coverage as $key=>$flag)if(!is_string($key)||!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$key)||!is_bool($flag))fail('记录覆盖信息不正确。');
    if($preferences['enabled'])requireActiveMembership($db,$user,$config);
    $db->beginTransaction();lockActiveUser($db,$uid);
    $q=$db->prepare('SELECT revision FROM club_automation WHERE user_id=? FOR UPDATE');$q->execute([$uid]);$current=$q->fetchColumn();
    if($preferences['enabled'] && (int)($current?:0)!==$revision){$db->rollBack();respond(409,['error'=>'另一台设备已更新自动跟进设置。请核对后重新保存。','code'=>'settings_conflict']);}
    $q=$db->prepare('SELECT revision FROM app_states WHERE user_id=?');$q->execute([$uid]);$latest=(int)($q->fetchColumn()?:0);
    if($preferences['enabled']&&$latest!==$cloud){$db->rollBack();respond(409,['error'=>'记录已更新，请同步完成后再保存跟进设置。','code'=>'record_conflict']);}
    $claims=[];
    if($preferences['enabled'] && $coverage) {
        $keys=array_keys($coverage);sort($keys);$snapshot=cloudStoredState($db,$uid,$keys[0],$keys[count($keys)-1],false);
        foreach($coverage as $key=>$complete) {
            $meals=$snapshot['days'][$key]['meals']??[];
            $claims[$key]=['complete'=>$complete && count($meals)>0,'fingerprint'=>clubAutomationMealFingerprint($meals)];
        }
    }
    $next=(int)($current?:0)+1;
    // 配置变更即重置有界重试计数：终态 failed 的账号可由用户再次保存设置恢复调度。
    $db->prepare("INSERT INTO club_automation(user_id,revision,enabled,preferences_json,coverage_json,cloud_revision,next_run,updated_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE revision=VALUES(revision),enabled=VALUES(enabled),preferences_json=VALUES(preferences_json),coverage_json=VALUES(coverage_json),cloud_revision=VALUES(cloud_revision),next_run=VALUES(next_run),retry_count=0,updated_at=UTC_TIMESTAMP()")
        ->execute([$uid,$next,(int)$preferences['enabled'],json_encode($preferences,JSON_THROW_ON_ERROR),json_encode((object)$claims,JSON_THROW_ON_ERROR),$cloud]);
    $db->commit();respond(200,['revision'=>$next,'enabled'=>$preferences['enabled']]);
}
