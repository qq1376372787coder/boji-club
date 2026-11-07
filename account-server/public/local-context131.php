<?php
declare(strict_types=1);
/** User-submitted, read-only evidence. This never upserts business records. */
function localContextResolve131(PDO $db,int $uid,array $body,array $config): array {
    $conversation=$body['conversation_id']??'';$refs=$body['references']??null;$days=$body['local_records131']??null;
    if(!is_string($conversation)||!preg_match('/^[a-f0-9-]{36}$/Di',$conversation)||!is_array($refs)||!array_is_list($refs)||count($refs)<1||count($refs)>5)throw new RuntimeException('请选择1至5项记录。',422);
    if(!is_array($days)||count($days)>140||strlen(aiContextCanonical($days))>480000)throw new RuntimeException('记录较多，请缩小引用范围。',413);
    require_once __DIR__.'/cloud-validation.php';
    foreach($days as $date=>$day){aiContextDate($date);if(!is_array($day))throw new RuntimeException('本机记录格式不正确。',422);cloudValidate($day,'day','local_records');}
    $jobs=$body['local_jobs131']??[];
    if(!is_array($jobs)||count($jobs)>5)throw new RuntimeException('计划引用过多。',422);
    $resolved=[];$seen=[];
    foreach($refs as $ref){
        if(!is_array($ref)||!in_array($ref['kind']??null,AI_CONTEXT_KINDS,true))throw new RuntimeException('不支持的引用类型。',422);
        $from=aiContextDate($ref['from']??null);$to=aiContextDate($ref['to']??$from);
        if($to<$from||(new DateTimeImmutable($from))->diff(new DateTimeImmutable($to))->days>27)throw new RuntimeException('每项引用最多28天。',422);
        $id=$ref['resource_id']??'';if(!is_string($id)||strlen($id)>200)throw new RuntimeException('引用标识不正确。',422);
        $descriptor=['kind'=>$ref['kind'],'resource_id'=>$id,'from'=>$from,'to'=>$to];$key=aiContextCanonical($descriptor);
        if(isset($seen[$key]))continue;$seen[$key]=true;
        $subset=array_filter($days,fn($date)=>$date>=$from&&$date<=$to,ARRAY_FILTER_USE_KEY);
        if($ref['kind']==='plan_version'&&str_starts_with(strtolower($id),'ai:')){
            $jobID=substr(strtolower($id),3);$job=$jobs[$jobID]??null;
            if(!preg_match('/^[a-f0-9-]{36}$/Di',$jobID)||!is_array($job)||($job['status']??'')!=='succeeded'||($job['result']['kind']??'')!=='plan')throw new RuntimeException('这份本机计划不可引用。',422);
            $sessions=$job['result']['sessions']??[];if(!is_array($sessions)||count($sessions)>28)throw new RuntimeException('计划格式不正确。',422);
            foreach($sessions as $session)cloudValidate($session,'session','local_plan');
            $descriptor['_job']=['result'=>['sessions'=>$sessions]];
        }
        $snapshot=aiContextProjection($descriptor,$subset);unset($descriptor['_job']);
        $has=false;foreach($snapshot as &$row){$row['source_tier131']='local_snapshot';foreach(['measurements','meals','exercises','sessions','plan_version'] as $field)if(!empty($row[$field]))$has=true;}unset($row);
        if(!$has&&$ref['kind']!=='plan_day')throw new RuntimeException('这项记录已删除或没有可分析内容，请重新选择。',410);
        $version=hash('sha256',aiContextCanonical($snapshot));
        $label=is_string($ref['label131']??null)?mb_substr($ref['label131'],0,120):$from.' · 本机记录';
        $resolved[]=$descriptor+['id'=>'ref/'.(count($resolved)+1),'source_version'=>$version,'label'=>$label,'source_tier131'=>'local_snapshot','read_only131'=>true,'snapshot'=>$snapshot];
    }
    $encoded=aiContextCanonical($resolved);if(strlen($encoded)>120000)throw new RuntimeException('引用内容较多，请缩小范围。',413);
    $bundle=businessUUID();$owns=!$db->inTransaction();if($owns)$db->beginTransaction();
    try{
        lockActiveUser($db,$uid);
        require_once __DIR__.'/usage-guard131.php';usageGuard131($db,$uid,$config,'context');
        $db->prepare('DELETE FROM ai_context_bundles WHERE user_id=? AND expires_at<UTC_TIMESTAMP()')->execute([$uid]);
        $q=$db->prepare('SELECT count(*) FROM ai_context_bundles WHERE user_id=? AND expires_at>=UTC_TIMESTAMP()');$q->execute([$uid]);
        if((int)$q->fetchColumn()>=300)throw new RuntimeException('今天引用次数较多，请稍后再试。',429);
        $db->prepare('INSERT INTO ai_context_bundles(id,user_id,conversation_id,content_hash,snapshot_cipher,expires_at,created_at) VALUES(?,?,?,?,?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 24 HOUR),UTC_TIMESTAMP())')->execute([$bundle,$uid,$conversation,hash('sha256',$encoded),aiContextSeal($resolved,$config)]);
        if($owns)$db->commit();
    }catch(Throwable $e){if($owns&&$db->inTransaction())$db->rollBack();throw $e;}
    return ['bundle_id'=>$bundle,'references'=>$resolved,'read_only131'=>true];
}
function localContextIsReadOnly131(array $references): bool {
    foreach($references as $reference)if(($reference['read_only131']??false)===true)return true;
    return false;
}
