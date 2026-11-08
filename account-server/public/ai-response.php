<?php
declare(strict_types=1);

// Stable, opaque account ownership; never sent to model providers or exposed to clients.
function aiQuotaOwner(int $userID,array $config): string {
    return hash_hmac('sha256','ai-quota:'.$userID,$config['otp_secret']);
}

// Deterministic server-side job id for one client job (account bound, no secrets exposed).
function aiJobID(array $user, string $clientId, array $config): string {
    $hex = hash_hmac('sha256', $user['id'] . ':ai:' . $clientId, $config['otp_secret']);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}

function aiQuotaRequest(array $config,string $action,array $body): array {
    if(!in_array($action,['usage','erase'],true)) throw new RuntimeException('ai_cleanup');
    $token=$config['ai_proxy_token']??'';
    if(strlen($token)<24) throw new RuntimeException('ai_cleanup');
    $context=stream_context_create(['http'=>['method'=>'POST','header'=>"Content-Type: application/json\r\nAuthorization: Bearer ".$token."\r\n",'content'=>json_encode($body,JSON_THROW_ON_ERROR),'timeout'=>15,'ignore_errors'=>true,'follow_location'=>0]]);
    $base=$config['ai_proxy_base_url']??'http://127.0.0.1:8787';
    if(!is_string($base)||!preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base)) throw new RuntimeException('ai_cleanup');
    $raw=@file_get_contents($base.'/v1/account-quota/'.$action,false,$context);
    $status=502;foreach($http_response_header??[] as $line) if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$match)) $status=(int)$match[1];
    $result=json_decode($raw===false?'':$raw,true);
    if($status!==200 || !is_array($result)) {
        if($action==='erase') throw new RuntimeException('ai_cleanup');
        fail('分析用量暂不可用，请稍后重试。',503);
    }
    return $result;
}

function aiCompletionKinds(string $resultKind): array {
    return match($resultKind) {
        'plan'=>['generate_plan','parse_plan'], 'plan_notes'=>['parse_plan'],
        'meal','meal_batch'=>['food'], 'report'=>['report'], 'weekly_review'=>['weekly_review'], 'coach'=>['coach'],
        default=>[],
    };
}

function aiMarkCompleted(PDO $db, int $userID, string $serverID, array $response): void {
    if(($response['status']??'')!=='succeeded' || !is_array($response['result']??null)) return;
    $kinds=aiCompletionKinds($response['result']['kind']??'');
    if(!$kinds) return;
    $marks=implode(',',array_fill(0,count($kinds),'?'));
    $db->prepare('UPDATE ai_user_jobs SET completed_at=COALESCE(completed_at,UTC_TIMESTAMP()) WHERE user_id=? AND server_job_id=? AND kind IN ('.$marks.')')->execute([$userID,$serverID,...$kinds]);
}

function aiQuotaFailure(?int $now=null): never {
    $now ??= time();
    $retry=86400-(($now+8*3600)%86400);
    header('Retry-After: '.$retry);
    respond(429,['error'=>'今日分析次数已达上限，北京时间零点恢复；输入已保留。','code'=>'quota_exceeded','retry_after'=>$retry]);
}

function publicAIResponse(array $value): array {
    $allowed = ['id','status','result','provider','model','error_code','error_message','retry_started','retry_after','created','updated','kind','date','error','code','source_status','source_revision','source_note'];
    $result = array_intersect_key($value, array_flip($allowed));
    foreach (['error','error_message'] as $key) {
        if (!isset($result[$key])) continue;
        $text = $result[$key];
        if (!is_string($text) || strlen($text) > 1500 || preg_match('/Traceback|<html|\{"|Bearer\s|sk-[A-Za-z0-9]{12}/i', $text)) {
            $result[$key] = '分析暂未完成，原输入已保留，请稍后重试。';
        }
    }
    return $result;
}

function weeklyAiJobID(int $userId, string $clientId, array $config): string {
    $hex = hash_hmac('sha256', $userId . ':' . $clientId, $config['otp_secret']);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}

function verifiedAICompletion(PDO $db, int $userId, string $clientId, string $kind): bool {
    global $config;
    $clientId = strtolower($clientId);
    if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$clientId)) return false;
    $statement = $db->prepare('SELECT server_job_id,kind,completed_at FROM ai_user_jobs WHERE user_id=? AND client_job_id=?'); $statement->execute([$userId,$clientId]); $job = $statement->fetch();
    if ($job && $job['kind'] !== $kind) return false;
    if ($job && $job['completed_at'] !== null) return true;
    // Legacy weekly jobs were not mapped. Their deterministic ID still binds them to this user.
    if (!$job && $kind !== 'weekly_review') return false;
    $serverId = $job['server_job_id'] ?? weeklyAiJobID($userId,$clientId,$config);
    if (strlen((string)($config['ai_proxy_token'] ?? '')) < 24) return false;
    // 后台 ai-completion-refresh 定时对账是主路径；这里只是兜底，超时放宽到 4 秒，
    // 避免 worker 繁忙时把已完成任务误判成「处理中」。
    $context = stream_context_create(['http'=>['header'=>"Authorization: Bearer ".$config['ai_proxy_token']."\r\n",'timeout'=>4,'ignore_errors'=>true,'follow_location'=>0]]);
    $raw = @file_get_contents(privateAiBase($config).'/v1/jobs/'.$serverId,false,$context);
    $result = is_string($raw) ? json_decode($raw,true) : null;
    if (($result['status'] ?? '') !== 'succeeded' || ($result['result']['kind'] ?? '') !== $kind) return false;
    $db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,completed_at,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE completed_at=COALESCE(completed_at,UTC_TIMESTAMP())')->execute([$userId,$clientId,$serverId,$kind]);
    return true;
}

/** Batch-verify AI completions so club pages do not perform one HTTP call per record. */

function verifiedAICompletions(PDO $db,int $userId,array $refs): array {
    $wanted=[];$servers=[];
    foreach($refs as $ref){
        $id=strtolower((string)($ref['id']??''));$kind=(string)($ref['kind']??'');
        if(!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$id))continue;
        if(!in_array($kind,['weekly_review','report'],true))continue;
        $wanted[$id]=$kind;
    }
    if(!$wanted)return [];
    $keys=array_keys($wanted);
    $marks=implode(',',array_fill(0,count($keys),'?'));
    $q=$db->prepare('SELECT client_job_id,server_job_id,kind,completed_at FROM ai_user_jobs WHERE user_id=? AND client_job_id IN ('.$marks.')');
    $q->execute(array_merge([$userId],$keys));
    $done=[];$byServer=[];
    foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){
        $key=strtolower($row['client_job_id']);
        if($row['completed_at']!==null){$done[$key]=true;continue;}
        if(!isset($wanted[$key]))continue;
        $sid=strtolower((string)$row['server_job_id']);
        if($sid!=='')$byServer[$sid][]=$key;
    }
    foreach($wanted as $id=>$kind){
        if(isset($done[$id])||$kind!=='weekly_review')continue;
        $sid=weeklyAiJobID($userId,$id,$GLOBALS['config']);
        $byServer[strtolower($sid)][]=$id;
    }
    $token=$GLOBALS['config']['ai_proxy_token']??'';
    if(strlen($token)<24)return $done;
    foreach(array_chunk(array_keys($byServer),50) as $chunk){
        $payload=json_encode(['ids'=>array_values($chunk)],JSON_THROW_ON_ERROR);
        // 同上：后台定时对账为主，请求路径只做兜底，超时 4 秒。
        $context=stream_context_create(['http'=>['method'=>'POST','header'=>"Content-Type: application/json\r\nAuthorization: Bearer ".$token."\r\n", 'content'=>$payload,'timeout'=>4,'ignore_errors'=>true,'follow_location'=>0]]);
        $raw=@file_get_contents(privateAiBase($GLOBALS['config']).'/v1/jobs/metadata',false,$context);
        $result=is_string($raw)?json_decode($raw,true):null;
        if(!is_array($result))continue;
        foreach(($result['items']??[]) as $item){
            $sid=strtolower((string)($item['id']??''));
            if(($item['status']??'')!=='succeeded'||!isset($byServer[$sid]))continue;
            foreach($byServer[$sid] as $id){
                if(strtolower((string)$wanted[$id])!==strtolower((string)($item['kind']??'')))continue;
                $done[$id]=true;
                $db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,completed_at,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE completed_at=COALESCE(completed_at,UTC_TIMESTAMP())')
                    ->execute([$userId,$id,$sid,$wanted[$id]]);
            }
        }
    }
    return $done;
}

function privateAiBase(array $config): string {
    $base = $config['ai_proxy_base_url'] ?? 'http://127.0.0.1:8787';
    return is_string($base) && preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base) ? $base : 'http://127.0.0.1:8787';
}
