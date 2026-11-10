<?php
declare(strict_types=1);
function taskRecoveryCursor(?array $row): ?string {
    return $row===null?null:rtrim(strtr(base64_encode(json_encode([$row['created_at'],$row['client_job_id']],JSON_THROW_ON_ERROR)),'+/','-_'),'=');
}
function taskRecoveryPosition(string $cursor): ?array {
    if($cursor==='')return null;
    if(strlen($cursor)>256||!preg_match('/^[A-Za-z0-9_-]+$/D',$cursor))throw new InvalidArgumentException('cursor');
    $raw=base64_decode(strtr($cursor,'-_','+/'),true);$value=$raw===false?null:json_decode($raw,true);
    if(!is_array($value)||count($value)!==2||!is_string($value[0])||!preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/D',$value[0])||!is_string($value[1])||!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$value[1]))throw new InvalidArgumentException('cursor');
    return $value;
}
function taskRecoveryPage(PDO $db,int $uid,array $config,array $query): array {
    $target=$query['id']??null;
    if($target!==null && (!is_string($target)||!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$target)))fail('任务编号不正确。');
    try{$position=taskRecoveryPosition((string)($query['cursor']??''));}catch(InvalidArgumentException){fail('任务分页标识不正确。');}
    $sql='SELECT client_job_id,server_job_id,kind,created_at FROM ai_user_jobs WHERE user_id=?';$args=[$uid];
    if($target!==null){$sql.=' AND client_job_id=?';$args[]=$target;}
    else {
        // Archived reports remain discoverable beyond temporary task retention.
        $sql.=" AND (created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY) OR kind IN ('report','coach'))";
        if($position){$sql.=' AND (created_at<? OR (created_at=? AND client_job_id<?))';array_push($args,$position[0],$position[0],$position[1]);}
    }
    $q=$db->prepare($sql.' ORDER BY created_at DESC,client_job_id DESC LIMIT 51');$q->execute($args);$rows=$q->fetchAll(PDO::FETCH_ASSOC);
    $more=$target===null && count($rows)>50;$rows=array_slice($rows,0,50);
    if(!$rows)return ['items'=>[],'next_cursor'=>null];
    $token=$config['ai_proxy_token']??'';if(strlen($token)<24)fail('AI 服务尚未配置。',503);
    $context=stream_context_create(['http'=>['method'=>'POST','header'=>"Content-Type: application/json\r\nAuthorization: Bearer ".$token."\r\n",'content'=>json_encode(['ids'=>array_column($rows,'server_job_id')],JSON_THROW_ON_ERROR),'timeout'=>10,'ignore_errors'=>true,'follow_location'=>0]]);
    $raw=@file_get_contents(privateAiBase($config).'/v1/jobs/metadata',false,$context);$result=json_decode($raw===false?'':$raw,true);
    $status=502;foreach($http_response_header??[] as $line)if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$match))$status=(int)$match[1];
    if($status!==200||!is_array($result['items']??null))fail('任务列表暂不可用，请稍后重试。',503);
    $allowed=[];foreach($rows as $row)$allowed[$row['server_job_id']]=$row;
    $byID=[];foreach($result['items'] as $item)if(isset($allowed[$item['id']??'']) && ($item['status']??'')!=='deleted')$byID[$item['id']]=$item;
    $items=[];foreach($rows as $row) {
        $item=$byID[$row['server_job_id']]??null;if(!$item)continue;
        $items[]=['id'=>$row['client_job_id'],'kind'=>$row['kind'],'date'=>$item['date'],'status'=>$item['status'],'created'=>$item['created'],...((in_array($item['purpose']??'', ['workout','weekly'],true))?['purpose'=>$item['purpose']]:[])];
    }
    // Advance by scanned mappings, even if an entire worker page has expired.
    return ['items'=>$items,'next_cursor'=>$more?taskRecoveryCursor($rows[count($rows)-1]):null];
}
