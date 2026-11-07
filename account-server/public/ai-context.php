<?php
declare(strict_types=1);
require_once __DIR__.'/cloud-parts.php';
require_once __DIR__.'/local-context131.php';

const AI_CONTEXT_KINDS=['body_measurement','body_range','workout_session','workout_range','meal_entry','meal_day','plan_day','plan_version'];
function aiContextDate(mixed $v): string {
    if(!is_string($v))throw new RuntimeException('请选择明确日期。',422);
    $d=DateTimeImmutable::createFromFormat('!Y-m-d',$v);
    if(!$d||$d->format('Y-m-d')!==$v)throw new RuntimeException('引用日期不正确。',422);
    return $v;
}
function aiContextPick(array $value,array $keys): array {return array_intersect_key($value,array_flip($keys));}
function aiContextDay(PDO $db,int $uid,string $date,?array $legacy=null): array {
    $part=cloudPartGet($db,$uid,'d/'.$date);
    return $part??($legacy['days'][$date]??[]);
}
function aiContextCanonical(mixed $value): string {
    $sort=function($v)use(&$sort){if(!is_array($v))return $v;if(!array_is_list($v))ksort($v);foreach($v as &$x)$x=$sort($x);return $v;};
    return json_encode($sort($value),JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
}
/** Narrow, server-authoritative facts. No raw HealthKit, media or profile blobs. */
function aiContextProjection(array $reference,array $days): array {
    $kind=$reference['kind'];$id=strtolower((string)($reference['resource_id']??''));$result=[];
    foreach($days as $date=>$day){
        $row=['date'=>$date];
        if(str_starts_with($kind,'body_')){
            $deleted=array_map('strtolower',$day['deletedBodyMeasurementIDs']??[]);
            $measurements=$day['bodyMeasurements']??(isset($day['bodyWeight'])?[$day['bodyWeight']]:[]);
            $rows=[];foreach($measurements as $m){
                if(in_array(strtolower((string)($m['id']??'')),$deleted,true)||(!isset($m['kilograms'])&&!isset($m['bodyFatPercentage'])&&!isset($m['waistCircumferenceCM'])))continue;
                if($kind==='body_measurement'&&strtolower((string)($m['id']??''))!==$id)continue;
                $rows[]=aiContextPick($m,['id','kilograms','bodyFatPercentage','waistCircumferenceCM','recordedAt','updatedAt','date','source']);
            }$row['measurements']=$rows;
        }elseif(str_starts_with($kind,'meal_')){
            $meals=[];foreach($day['meals']??[] as $m){
                if($kind==='meal_entry'&&strtolower((string)($m['id']??''))!==$id)continue;
                $meals[]=aiContextPick($m,['id','name','category','calories','protein','carbs','fat','portion','nutritionKnown','estimated','consumedFraction']);
            }$row['meals']=$meals;$row['status']='saved_records_only';
            $totals=['known_entries'=>0,'unknown_entries'=>0,'calories'=>0.0,'protein'=>0.0,'carbs'=>0.0,'fat'=>0.0];
            foreach($meals as $m){if(($m['nutritionKnown']??true)===false){$totals['unknown_entries']++;continue;}$totals['known_entries']++;foreach(['calories','protein','carbs','fat'] as $k)$totals[$k]+=(float)($m[$k]??0);}$row['recorded_known_totals']=$totals;
        }elseif($kind==='plan_version'){
            if(str_starts_with($id,'ai:')&&isset($reference['_job'])){
                $job=$reference['_job'];$plan=$job['result']['sessions']??null;
                if(is_array($plan))$row['plan_version']=['id'=>$id,'title'=>'AI候选计划','status'=>'draft','sessions'=>$plan];
            }
            foreach($day['planVersions']??[] as $v)if(strtolower((string)($v['id']??''))===$id)$row['plan_version']=aiContextPick($v,['id','title','source','start','duration','sessions','scopeDates','retainedDates','recordedAt','planDescription','planIntent']);
        }else{
            $exercises=[];$sessions=[];$targets=[];
            if($kind==='plan_day')foreach($day['workoutSessions']??[] as $session)foreach($session['executionBaseline']['sets']??[] as $target)$targets[strtolower($target['id']??'')]=$target;
            foreach($day['workoutSessions']??[] as $session){if($kind==='plan_day'&&$id!=='')continue;if($kind==='workout_session'&&strtolower((string)($session['id']??''))!==$id)continue;$sessions[]=aiContextPick($session,['id','startedAt','endedAt','savedAt','confirmed','cancelledAt','pauseIntervals']);}
            foreach($day['exercises']??[] as $ex){
                if($kind==='workout_session'&&strtolower((string)($ex['workoutSessionID']??''))!==$id)continue;
                if($kind==='plan_day'&&$id!==''){
                    $owner=strtolower((string)($ex['planID']??''));
                    $cycleOwner=strtolower((string)($day['planCycle']['sourceJobID']??('legacy-plan-'.($day['planCycle']['start']??''))));
                    if($owner!==$id && !($owner===''&&$cycleOwner===$id))continue;
                }
                $e=aiContextPick($ex,['id','name','muscle','libraryID','libraryQuery','workoutSessionID']);$e['sets']=[];
                foreach($ex['sets']??[] as $set){
                    if($kind!=='plan_day'&&(empty($set['completed'])||($set['actualEntered']??true)===false))continue;
                    if($kind==='plan_day'){
                        $target=$targets[strtolower($set['id']??'')]??null;
                        if($target){$set=['id'=>$set['id'],'weight'=>$target['targetWeight']??null,'reps'=>$target['targetReps']??null,'durationSeconds'=>$target['targetSeconds']??null,'completed'=>false];}
                        elseif(!empty($set['completed'])){$set=['id'=>$set['id'],'weight'=>null,'reps'=>null,'durationSeconds'=>null,'completed'=>false,'target_unknown'=>true];}
                    }
                    $e['sets'][]=aiContextPick($set,['id','weight','reps','durationSeconds','completed','actualEntered','target_unknown']);
                }$exercises[]=$e;
            }$row['exercises']=$exercises;$row['sessions']=$sessions;$row['status']=$kind==='plan_day'?'planned_targets_not_actual':'recorded_actual_sets_only';
        }
        $result[]=$row;
    }
    return $result;
}
function aiContextKey(array $config): string {
    $secret=(string)($config['ai_context_encryption_key']??$config['ai_proxy_token']??'');
    if(strlen($secret)<24)throw new RuntimeException('引用安全配置不可用。',503);
    return hash_hkdf('sha256',$secret,32,'boji-ai-context-v1');
}
function aiContextSeal(array $value,array $config): string {
    $iv=random_bytes(12);$cipher=openssl_encrypt(aiContextCanonical($value),'aes-256-gcm',aiContextKey($config),OPENSSL_RAW_DATA,$iv,$tag,'boji-context',16);
    if($cipher===false)throw new RuntimeException('引用保存失败。',503);
    return base64_encode($iv.$tag.$cipher);
}
function aiContextOpen(string $value,array $config): array {
    $raw=base64_decode($value,true);if(!$raw||strlen($raw)<29)throw new RuntimeException('引用已失效。',410);
    $plain=openssl_decrypt(substr($raw,28),'aes-256-gcm',aiContextKey($config),OPENSSL_RAW_DATA,substr($raw,0,12),substr($raw,12,16),'boji-context');
    if($plain===false)throw new RuntimeException('引用已失效。',410);
    return json_decode($plain,true,64,JSON_THROW_ON_ERROR);
}
function aiContextResolve(PDO $db,int $uid,array $body,array $config): array {
    if(array_key_exists('local_records131',$body))return localContextResolve131($db,$uid,$body,$config);
    $refs=$body['references']??null;$conversation=$body['conversation_id']??'';
    if(!is_string($conversation)||!preg_match('/^[a-f0-9-]{36}$/Di',$conversation)||!is_array($refs)||!array_is_list($refs)||!count($refs)||count($refs)>5)throw new RuntimeException('请选择1至5项记录。',422);
    $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);$raw=$q->fetchColumn();$legacy=is_string($raw)?json_decode($raw,true):[];
    $resolved=[];$seen=[];
    foreach($refs as $ref){
        if(!is_array($ref)||!in_array($ref['kind']??null,AI_CONTEXT_KINDS,true))throw new RuntimeException('不支持的引用类型。',422);
        $from=aiContextDate($ref['from']??null);$to=aiContextDate($ref['to']??$from);
        $span=(new DateTimeImmutable($from))->diff(new DateTimeImmutable($to));
        if($to<$from||$span->days>27)throw new RuntimeException('每项引用最多选择28天。',422);
        $id=(string)($ref['resource_id']??'');if(strlen($id)>200)throw new RuntimeException('引用标识不正确。',422);
        $descriptor=['kind'=>$ref['kind'],'resource_id'=>$id,'from'=>$from,'to'=>$to];$identity=aiContextCanonical($descriptor);
        if(isset($seen[$identity]))continue;$seen[$identity]=true;
        $days=[];for($date=$from;$date<=$to;$date=(new DateTimeImmutable($date))->modify('+1 day')->format('Y-m-d'))$days[$date]=aiContextDay($db,$uid,$date,$legacy?:[]);
        if($ref['kind']==='plan_version'&&str_starts_with(strtolower($id),'ai:')){
            $jobID=substr($id,3);if(!preg_match('/^[a-f0-9-]{36}$/Di',$jobID))throw new RuntimeException('计划编号不正确。',422);
            $job=cloudPartGet($db,$uid,cloudPartJobKey($jobID));
            if(!$job)foreach($legacy['aiJobs']??[] as $j)if(strtolower((string)($j['id']??''))===strtolower($jobID))$job=$j;
            $meta=cloudPartGet($db,$uid,'meta')??$legacy;
            if(in_array(strtolower($jobID),array_map('strtolower',$meta['deletedAIJobIDs']??[]),true))$job=null;
            if(!$job||($job['status']??'')!=='succeeded')throw new RuntimeException('候选计划已删除或尚未同步。',410);
            $descriptor['_job']=$job;
        }
        $snapshot=aiContextProjection($descriptor,$days);
        unset($descriptor['_job']);
        $has=false;foreach($snapshot as $r)foreach(['measurements','meals','exercises','sessions','plan_version'] as $k)if(!empty($r[$k]))$has=true;
        if(!$has&&$ref['kind']!=='plan_day')throw new RuntimeException('记录不存在、尚未同步或已删除，请重新选择。',410);
        $version=hash('sha256',aiContextCanonical($snapshot));
        if(isset($ref['source_version'])&&!hash_equals($version,(string)$ref['source_version']))throw new RuntimeException('引用记录已更新，请核对后刷新来源。',409);
        $labels=['body_measurement'=>'身体测量','body_range'=>'身体数据','workout_session'=>'本场训练','workout_range'=>'训练记录','meal_entry'=>'饮食记录','meal_day'=>'当天饮食','plan_day'=>'当天计划','plan_version'=>'整套计划'];
        $resolved[]=$descriptor+['source_version'=>$version,'id'=>'ref/'.(count($resolved)+1),'label'=>$from.($to!==$from?' 至 '.$to:'').' · '.$labels[$ref['kind']],'snapshot'=>$snapshot];
    }
    $encoded=aiContextCanonical($resolved);if(strlen($encoded)>120000)throw new RuntimeException('引用内容较多，请缩小范围。',413);
    $bundleID=businessUUID();$hash=hash('sha256',$encoded);
    $db->prepare('INSERT INTO ai_context_bundles(id,user_id,conversation_id,content_hash,snapshot_cipher,expires_at,created_at) VALUES(?,?,?,?,?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 30 DAY),UTC_TIMESTAMP())')->execute([$bundleID,$uid,$conversation,$hash,aiContextSeal($resolved,$config)]);
    return ['bundle_id'=>$bundleID,'content_hash'=>$hash,'references'=>$resolved,'bytes'=>strlen($encoded),'token_estimate'=>(int)ceil(mb_strlen($encoded)/1.5),'schema_version'=>1];
}
function aiContextLoad(PDO $db,int $uid,string $id,string $conversation,array $config,bool $allowUpdated=false): array {
    $q=$db->prepare('SELECT * FROM ai_context_bundles WHERE id=? AND user_id=? AND conversation_id=? AND expires_at>UTC_TIMESTAMP()');$q->execute([$id,$uid,$conversation]);$row=$q->fetch(PDO::FETCH_ASSOC);
    if(!$row)throw new RuntimeException('引用已失效，请重新选择。',410);
    $refs=aiContextOpen($row['snapshot_cipher'],$config);
    // Re-resolve without creating another stored bundle. Withdrawals/deletions always invalidate.
    $legacy=[];
    if(array_filter($refs,fn($ref)=>($ref['read_only131']??false)!==true)){
    $q=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$q->execute([$uid]);$legacy=json_decode((string)($q->fetchColumn()?:'{}'),true);
    }
    foreach($refs as $ref){if(($ref['read_only131']??false)===true)continue;$days=[];for($date=$ref['from'];$date<=$ref['to'];$date=(new DateTimeImmutable($date))->modify('+1 day')->format('Y-m-d'))$days[$date]=aiContextDay($db,$uid,$date,$legacy);
        if($ref['kind']==='plan_version'&&str_starts_with(strtolower($ref['resource_id']),'ai:')){
            $jobID=substr($ref['resource_id'],3);$job=cloudPartGet($db,$uid,cloudPartJobKey($jobID));
            if(!$job)foreach($legacy['aiJobs']??[] as $j)if(strtolower((string)($j['id']??''))===strtolower($jobID))$job=$j;
            $meta=cloudPartGet($db,$uid,'meta')??$legacy;
            if(!$job||in_array(strtolower($jobID),array_map('strtolower',$meta['deletedAIJobIDs']??[]),true))throw new RuntimeException('候选计划已撤回。',410);
            $ref['_job']=$job;
        }
        $current=aiContextProjection($ref,$days);$version=hash('sha256',aiContextCanonical($current));
        if(!hash_equals($ref['source_version'],$version))throw new RuntimeException('引用已变化或撤回，请刷新来源。',409);
    }
    return ['bundle_id'=>$id,'references'=>$refs,'content_hash'=>$row['content_hash']];
}

require_once __DIR__.'/ai-consent.php';
