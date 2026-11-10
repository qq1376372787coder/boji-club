<?php
declare(strict_types=1);
require_once __DIR__.'/media-store.php';
require_once __DIR__.'/profile-facts.php';

// Snapshot size is not an account quota. Each independently validated day/job
// travels separately. A bounded part keeps PHP and HTTP memory predictable.
const CLOUD_PART_BYTES = 4 * 1024 * 1024;
const CLOUD_PAGE_BYTES = 2 * 1024 * 1024;
function cloudPartKey(string $key): bool {
    return $key==='meta' || preg_match('#^d/\d{4}-\d{2}-\d{2}$#D',$key)===1 || preg_match('#^j/[a-f0-9]{64}$#D',$key)===1;
}
function cloudPartJobKey(string $id): string { return 'j/'.hash('sha256',strtolower($id)); }
function cloudPartQuery(PDO $db,string $sql,array $args=[]): PDOStatement { $q=$db->prepare($sql);$q->execute($args);return $q; }
function cloudPartGet(PDO $db,int $uid,string $key): ?array {
    $raw=cloudPartQuery($db,'SELECT payload_json FROM cloud_parts WHERE user_id=? AND part_key=?',[$uid,$key])->fetchColumn();
    return is_string($raw)?json_decode($raw,true,64,JSON_THROW_ON_ERROR):null;
}
/**
 * Swift Codable dictionaries must stay JSON objects. PHP decodes an empty JSON
 * object to [] and would re-encode it as [], which the Swift client cannot
 * decode (e.g. planShiftRecord.replaced={} after a shift without replacement).
 * Normalize every known dictionary-shaped field at the single write boundary.
 */
function cloudPartNormalizeDictionaries(array $value): array {
    $review=static function(array $review): array {
        if(array_key_exists('baseline',$review)&&is_array($review['baseline']))$review['baseline']=(object)$review['baseline'];
        return $review;
    };
    if(isset($value['weeklyReview'])&&is_array($value['weeklyReview']))$value['weeklyReview']=$review($value['weeklyReview']);
    if(isset($value['weeklyReviewHistory'])&&is_array($value['weeklyReviewHistory']))foreach($value['weeklyReviewHistory'] as &$item)if(is_array($item))$item=$review($item);unset($item);
    if(isset($value['planShifts'])&&is_array($value['planShifts'])) {
        foreach($value['planShifts'] as &$shift) {
            if(!is_array($shift))continue;
            foreach(['moves','replaced','sourceCycles'] as $field)if(array_key_exists($field,$shift)&&is_array($shift[$field]))$shift[$field]=(object)$shift[$field];
        }
        unset($shift);
    }
    return $value;
}
function cloudPartPut(PDO $db,int $uid,string $key,array $value): void {
    $value=cloudPartNormalizeDictionaries($value);
    $raw=json_encode($value,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
    if(strlen($raw)>CLOUD_PART_BYTES) fail('单日记录或单份分析超过4MiB，请联系支持处理；本机和云端原记录保留。',413);
    $date=str_starts_with($key,'d/')?substr($key,2):($value['request']['date']??null);
    cloudPartQuery($db,'INSERT INTO cloud_parts(user_id,part_key,payload_json,content_hash,date_key,byte_size) VALUES(?,?,?,?,?,?) ON DUPLICATE KEY UPDATE payload_json=VALUES(payload_json),content_hash=VALUES(content_hash),date_key=VALUES(date_key),byte_size=VALUES(byte_size)',[$uid,$key,$raw,hash('sha256',$raw),$date,strlen($raw)]);
    if(!str_starts_with($key,'d/'))return;
    cloudPartQuery($db,'DELETE FROM cloud_meal_sources WHERE user_id=? AND date_key=?',[$uid,$date]);
    cloudPartQuery($db,'DELETE FROM cloud_media_refs WHERE user_id=? AND date_key=?',[$uid,$date]);
    foreach($value['meals']??[] as $meal) {
        if(!empty($meal['sourceAIJobID']))cloudPartQuery($db,'INSERT IGNORE INTO cloud_meal_sources(user_id,source_hash,date_key) VALUES(?,?,?)',[$uid,hash('sha256',$meal['sourceAIJobID']),$date]);
        foreach(['photoRemoteID','photoFilename'] as $field)if(!empty($meal[$field]))cloudPartQuery($db,'INSERT IGNORE INTO cloud_media_refs(user_id,media_id,date_key) VALUES(?,?,?)',[$uid,strtolower($meal[$field]),$date]);
    }
}
function cloudPartDelete(PDO $db,int $uid,string $key): void {
    cloudPartQuery($db,'DELETE FROM cloud_parts WHERE user_id=? AND part_key=?',[$uid,$key]);
    if(str_starts_with($key,'d/')) {
        cloudPartQuery($db,'DELETE FROM cloud_meal_sources WHERE user_id=? AND date_key=?',[$uid,substr($key,2)]);
        cloudPartQuery($db,'DELETE FROM cloud_media_refs WHERE user_id=? AND date_key=?',[$uid,substr($key,2)]);
    }
}
function cloudPartSplit(array $state): array {
    $parts=[];foreach((array)($state['days']??[]) as $date=>$day) {
        if(isset($day['weeklyReview']['baseline']))$day['weeklyReview']['baseline']=(object)$day['weeklyReview']['baseline'];
        if(isset($day['weeklyReviewHistory']))foreach($day['weeklyReviewHistory'] as &$review)$review['baseline']=(object)($review['baseline']??[]);unset($review);
        $parts['d/'.$date]=$day;
    }
    foreach($state['aiJobs']??[] as $job) {$job['request']['payload']=(object)$job['request']['payload'];$parts[cloudPartJobKey($job['id'])]=$job;}
    unset($state['days'],$state['aiJobs'],$state['_partitioned']);$parts['meta']=$state;return $parts;
}
function cloudPartMetadata(array $meta): array { return [...$meta,'days'=>(object)[],'aiJobs'=>[],'_partitioned'=>2]; }
function cloudCommitLock(): mixed {
    $namespace=hash('sha256',(string)($GLOBALS['config']['dsn']??'default'));
    $lock=fopen(sys_get_temp_dir().'/bojiclub-cloud-commit-v59-'.$namespace.'.lock','c');
    if(!$lock||!flock($lock,LOCK_EX|LOCK_NB)){header('Retry-After: 5');respond(429,['error'=>'云端正在整理记录，5秒后自动重试；原记录保留。']);}
    return $lock;
}
function cloudJsonStringEnd(string $raw,int $start): int {
    $position=$start+1;
    while(($quote=strpos($raw,'"',$position))!==false) {
        $slashes=0;for($i=$quote-1;$i>$start&&$raw[$i]==='\\';$i--)$slashes++;
        if($slashes%2===0)return $quote+1;$position=$quote+1;
    }
    throw new RuntimeException('Invalid stored JSON string');
}
function cloudJsonValueEnd(string $raw,int $start): int {
    if(($raw[$start]??'')==='"')return cloudJsonStringEnd($raw,$start);
    if(!in_array($raw[$start]??'',['{','['],true))return $start+strcspn($raw,",]} \t\r\n",$start);
    $depth=0;$length=strlen($raw);
    for($i=$start;$i<$length;$i++) {
        $char=$raw[$i];if($char==='"'){$i=cloudJsonStringEnd($raw,$i)-1;continue;}
        if($char==='{'||$char==='[')$depth++;
        elseif($char==='}'||$char===']'){if(--$depth===0)return $i+1;}
    }
    throw new RuntimeException('Invalid stored JSON value');
}
function cloudJsonEntries(string $raw,bool $object): Generator {
    $position=strspn($raw," \t\r\n");$length=strlen($raw);$index=0;
    if(($raw[$position]??'')!==($object?'{':'['))throw new RuntimeException('Invalid stored collection');$position++;
    while($position<$length) {
        $position+=strspn($raw," \t\r\n",$position);
        if(($raw[$position]??'')===($object?'}':']'))return;
        if($object) {
            if(($raw[$position]??'')!=='"')throw new RuntimeException('Invalid stored key');
            $end=cloudJsonStringEnd($raw,$position);$key=json_decode(substr($raw,$position,$end-$position),true,64,JSON_THROW_ON_ERROR);$position=$end+strspn($raw," \t\r\n",$end);
            if(($raw[$position]??'')!==':')throw new RuntimeException('Invalid stored colon');$position++;
        } else $key=$index++;
        $position+=strspn($raw," \t\r\n",$position);$end=cloudJsonValueEnd($raw,$position);
        yield $key=>substr($raw,$position,$end-$position);
        $position=$end+strspn($raw," \t\r\n",$end);
        if(($raw[$position]??'')===',')$position++;
        elseif(($raw[$position]??'')!==($object?'}':']'))throw new RuntimeException('Invalid stored separator');
    }
    throw new RuntimeException('Incomplete stored collection');
}
function cloudPartEnsure(PDO $db,int $uid): void {
    $probe=cloudPartQuery($db,"SELECT JSON_UNQUOTE(JSON_EXTRACT(state_json,'$._partitioned')) AS version FROM app_states WHERE user_id=?",[$uid])->fetch();
    if(!$probe||$probe['version']==='2')return;
    $lock=cloudCommitLock();
    $db->beginTransaction();
    try {
        lockActiveUser($db,$uid);
        $row=cloudPartQuery($db,'SELECT state_json FROM app_states WHERE user_id=? FOR UPDATE',[$uid])->fetch();
        if($row) {
            $version=cloudPartQuery($db,"SELECT JSON_UNQUOTE(JSON_EXTRACT(state_json,'$._partitioned')) FROM app_states WHERE user_id=?",[$uid])->fetchColumn();
            if($version!=='2') {
                $meta=[];
                // Stream only one old day/report into PHP arrays at a time.
                foreach(cloudJsonEntries($row['state_json'],true) as $field=>$json) {
                    if($field==='days') {
                        foreach(cloudJsonEntries($json,true) as $date=>$value) {
                            $day=json_decode($value,true,64,JSON_THROW_ON_ERROR);
                            $normalized=cloudPartSplit(['days'=>[$date=>$day]]);cloudPartPut($db,$uid,'d/'.$date,$normalized['d/'.$date]);
                        }
                    } elseif($field==='aiJobs') {
                        foreach(cloudJsonEntries($json,false) as $value) {
                            $job=json_decode($value,true,64,JSON_THROW_ON_ERROR);$job['request']['payload']=(object)$job['request']['payload'];cloudPartPut($db,$uid,cloudPartJobKey($job['id']),$job);
                        }
                    } elseif($field!=='_partitioned')$meta[$field]=json_decode($json,true,64,JSON_THROW_ON_ERROR);
                }
                cloudPartPut($db,$uid,'meta',$meta);
                cloudPartQuery($db,'UPDATE app_states SET state_json=? WHERE user_id=?',[json_encode(cloudPartMetadata($meta),JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR),$uid]);
            }
        }
        $db->commit();
    } catch(Throwable $e) { if($db->inTransaction())$db->rollBack();throw $e; }
    finally {unset($GLOBALS["boji_active_preflight"]);flock($lock,LOCK_UN);fclose($lock);}
}
function cloudPartRevision(PDO $db,int $uid): int { return (int)(cloudPartQuery($db,'SELECT revision FROM app_states WHERE user_id=?',[$uid])->fetchColumn()?:0); }
function cloudPartAssertRevision(PDO $db,int $uid,int $revision): void {
    if(cloudPartRevision($db,$uid)!==$revision)respond(409,['error'=>'其他设备已更新记录，请重新读取后合并。']);
}
function cloudStoredState(PDO $db,int $uid,string $start='0000-00-00',string $end='9999-12-31',bool $jobs=true,bool $jobSummaries=false): array {
    $raw=cloudPartQuery($db,'SELECT state_json FROM app_states WHERE user_id=?',[$uid])->fetchColumn();
    if(!is_string($raw))return [];
    $meta=json_decode($raw,true,64,JSON_THROW_ON_ERROR);
    if(($meta['_partitioned']??null)!==2)return $meta;
    unset($meta['_partitioned']);$meta['days']=[];$meta['aiJobs']=[];
    $after='';
    $projection=$jobSummaries?"CASE WHEN part_key LIKE 'j/%' THEN JSON_OBJECT('id',JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.id')),'request',JSON_OBJECT('date',JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.request.date'))),'result',JSON_OBJECT('kind',JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.result.kind')))) ELSE payload_json END":"payload_json";
    do {
        $kindFilter=$jobs?'':" AND part_key LIKE 'd/%'";
        $q=cloudPartQuery($db,"SELECT part_key,".$projection." AS payload_json FROM cloud_parts WHERE user_id=? AND date_key>=? AND date_key<=? AND part_key>?".$kindFilter." ORDER BY part_key LIMIT 32",[$uid,$start,$end,$after]);$rows=$q->fetchAll();
        foreach($rows as $row) {
            $after=$row['part_key'];$part=json_decode($row['payload_json'],true,64,JSON_THROW_ON_ERROR);
            if(str_starts_with($after,'d/'))$meta['days'][substr($after,2)]=$part;
            elseif($jobs && str_starts_with($after,'j/'))$meta['aiJobs'][]=$part;
        }
    } while(count($rows)===32);
    return $meta;
}
// Legacy devices remain safe: small snapshots are compatible; a large history
// asks for an update instead of returning a truncated state that could overwrite it.
function cloudLegacyState(PDO $db,int $uid): array {
    $bytes=(int)cloudPartQuery($db,'SELECT COALESCE(SUM(byte_size),0) FROM cloud_parts WHERE user_id=?',[$uid])->fetchColumn();
    if($bytes>15*1024*1024) fail('历史记录已使用分批同步，请更新App后继续；所有原记录仍保留。',426);
    $state=cloudStoredState($db,$uid);
    foreach($state['days'] as &$day) {
        if(isset($day['weeklyReview']['baseline']))$day['weeklyReview']['baseline']=(object)$day['weeklyReview']['baseline'];
        if(isset($day['weeklyReviewHistory']))foreach($day['weeklyReviewHistory'] as &$review)$review['baseline']=(object)($review['baseline']??[]);unset($review);
    }unset($day);
    foreach($state['aiJobs'] as &$job)$job['request']['payload']=(object)$job['request']['payload'];unset($job);
    return $state;
}
function cloudPartSyncDay(PDO $db,int $uid,string $date,array $meta,string $uploadID): array {
    $days=[];$previous=[];$seen=[];$queue=[$date];$bytes=0;$changed=[];
    // Normalize connected meal dates as one observation. Applying day patches
    // independently could discard a moved meal before its old date is removed.
    while($queue) {
        $key=array_shift($queue);if(isset($seen[$key]))continue;$seen[$key]=true;
        $old=cloudPartGet($db,$uid,'d/'.$key);if($old!==null)$previous[$key]=$old;
        $staged=cloudPartQuery($db,'SELECT payload_json FROM cloud_upload_parts WHERE upload_id=? AND part_key=?',[$uploadID,'d/'.$key])->fetch();
        $next=$staged?($staged['payload_json']===null?null:json_decode($staged['payload_json'],true,64,JSON_THROW_ON_ERROR)):$old;
        if($next!==null)$days[$key]=$next;if($staged && $next!==null)$changed[$key]=true;
        $bytes+=strlen(json_encode([$old,$next],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR));
        if($bytes>12*1024*1024)fail('同一识别结果关联的冲突记录过多，请联系支持；原记录保留。',413);
        foreach(array_merge($old['meals']??[],$next['meals']??[]) as $meal) {
            if(empty($meal['sourceAIJobID']))continue;$hash=hash('sha256',$meal['sourceAIJobID']);
            $others=cloudPartQuery($db,'SELECT date_key FROM cloud_meal_sources WHERE user_id=? AND source_hash=? UNION SELECT date_key FROM cloud_upload_meal_sources WHERE upload_id=? AND source_hash=?',[$uid,$hash,$uploadID,$hash])->fetchAll(PDO::FETCH_COLUMN);
            foreach($others as $other)if(!isset($seen[$other]))$queue[]=$other;
        }
    }
    $input=[...$meta,'days'=>$days,'aiJobs'=>[]];$before=[...$meta,'days'=>$previous,'aiJobs'=>[]];
    $input=cloudPreserveLegacyExperience($input,$before);$input=cloudReconcileRecords($input,$before);
    $input['days']=(array)$input['days'];
    [$input]=decodedState(['state'=>$input]);
    if(!cloudPlanDraftsValid($input)) fail('训练周期或饮食确认信息格式不正确，原记录已保留。',400);
    foreach(array_intersect_key((array)$input['days'],$changed) as $key=>$day) if(!cloudDayExperienceValid((string)$key,$day)) fail('训练周期或饮食确认信息格式不正确，原记录已保留。',400);
    if(!cloudWorkoutSessionsPreserved($before,$input))fail('已有训练会话不能被旧设备覆盖，请更新设备后同步。',400);
    // R04：与整包路径等价的其余语义校验（计划变更、执行目标、自定义动作、洞察因果），
    // 只校验本次涉及对象，存量旧数据自身的旧问题不阻塞新上传。
    if(!cloudPlanChangesValid($input) || !cloudExecutionTargetsValid($input) || !cloudCustomExercisesValid($input)) fail('训练周期或饮食确认信息格式不正确，原记录已保留。',400);
    $uploadedEvents=[];$uploadedFeedback=[];
    foreach($input['days'] as $day) {
        foreach($day['insightEvents']??[] as $event)$uploadedEvents[]=$event;
        foreach($day['insightFeedback']??[] as $entry)$uploadedFeedback[]=$entry;
    }
    if($uploadedEvents||$uploadedFeedback) {
        $storedEvents=[];$storedFeedback=[];$window=array_fill_keys(array_keys($seen),true);$cursor='';
        do {
            $rows=cloudPartQuery($db,"SELECT part_key,payload_json FROM cloud_parts WHERE user_id=? AND part_key>? AND part_key LIKE 'd/%' ORDER BY part_key LIMIT 32",[$uid,$cursor])->fetchAll();
            foreach($rows as $row) {
                $cursor=$row['part_key'];$k=substr($row['part_key'],2);
                if(isset($window[$k]))continue;
                $part=json_decode($row['payload_json'],true,64,JSON_THROW_ON_ERROR);
                foreach($part['insightEvents']??[] as $event)$storedEvents[]=$event;
                foreach($part['insightFeedback']??[] as $entry)$storedFeedback[]=$entry;
            }
        } while(count($rows)===32);
        if(!cloudInsightEventsCompatible($uploadedEvents,$storedEvents) || !cloudInsightFeedbackCompatible($uploadedFeedback,$storedFeedback)) fail('洞察记录的引用关系不合法，原记录已保留。',400);
    }
    foreach(array_keys($seen) as $key)if(!isset($input['days']->$key))cloudPartDelete($db,$uid,'d/'.$key);
    foreach($input['days'] as $key=>$value){if(function_exists('actionGuardDayUpload'))actionGuardDayUpload($db,$uid,(string)$key,$previous[$key]??[],$value,$uploadID);cloudPartPut($db,$uid,'d/'.$key,$value);}
    return array_keys($seen);
}
function cloudPartCommit(PDO $db,int $uid,string $uploadID): array {
    // One normalization transaction at a time; reads and uploads do not wait.
    $lock=cloudCommitLock();
    $next=0;
    $db->beginTransaction();
    try {
        lockActiveUser($db,$uid);
        $upload=cloudPartQuery($db,'SELECT * FROM cloud_uploads WHERE id=? AND user_id=? FOR UPDATE',[$uploadID,$uid])->fetch();
        if(!$upload)fail('这次分批同步已过期，请重新开始；原记录保留。',410);
        if($upload['status']==='committed'){$db->commit();return ['revision'=>(int)$upload['committed_revision']];}
        $row=cloudPartQuery($db,'SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE',[$uid])->fetch();
        $current=$row?(int)$row['revision']:0;
        if($current!==(int)$upload['base_revision']){$db->rollBack();respond(409,['error'=>'其他设备已更新记录，请重新合并。','revision'=>$current]);}
        $received=(int)cloudPartQuery($db,'SELECT COUNT(*) FROM cloud_upload_parts WHERE upload_id=?',[$uploadID])->fetchColumn();
        if($received!==(int)$upload['expected_parts'])fail('同步分块尚未传完整，请继续上传；原记录保留。',409);
        if(function_exists('actionPreflightUpload')){actionPreflightUpload($db,$uid,$uploadID);$GLOBALS['boji_active_preflight']=true;}
        $oldMeta=cloudPartGet($db,$uid,'meta')??[];
        $staged=cloudPartQuery($db,"SELECT payload_json FROM cloud_upload_parts WHERE upload_id=? AND part_key='meta'",[$uploadID])->fetch();
        if($staged && $staged['payload_json']===null)fail('个人资料不能删除。');
        $meta=$staged?json_decode($staged['payload_json'],true,64,JSON_THROW_ON_ERROR):$oldMeta;
        if(!$meta)fail('同步资料尚未上传完整，请重试。');
        $meta['profile']=cloudPreserveLegacyIdentity($meta['profile']??[],$oldMeta['profile']??[]);
        $meta=cloudPreserveLegacyExperience([...$meta,'days'=>[],'aiJobs'=>[]],[...$oldMeta,'days'=>[],'aiJobs'=>[]]);
        $meta=cloudPreserveV2Meta([...$meta,'days'=>[],'aiJobs'=>[]],[...$oldMeta,'days'=>[],'aiJobs'=>[]]);
        foreach(['deletedAIJobIDs','deletedMediaIDs','deletedMealIDs','deletedExerciseIDs','deletedCustomExerciseIDs','deletedPlanDraftIDs','deletedPlanTemplateIDs'] as $field) {
            if(isset($meta[$field])||isset($oldMeta[$field]))$meta[$field]=array_values(array_unique(array_merge($meta[$field]??[],$oldMeta[$field]??[])));
        }
        [$meta]=decodedState(['state'=>$meta],false);
        if(!cloudExperienceValid($meta)) fail('训练周期、计划草稿或确认信息格式不正确，原记录已保留。',400);
        unset($meta['days'],$meta['aiJobs'],$meta['_partitioned']);
        $blocked=array_fill_keys(array_map('strtolower',$meta['deletedAIJobIDs']??[]),true);
        $after='';$daySeen=[];
        // Fetch one part at a time. Do not buffer a 30MiB/100MiB upload in PHP.
        while($part=cloudPartQuery($db,'SELECT part_key,payload_json FROM cloud_upload_parts WHERE upload_id=? AND part_key>? ORDER BY part_key LIMIT 1',[$uploadID,$after])->fetch()) {
            $key=$part['part_key'];$after=$key;if($key==='meta')continue;
            $value=$part['payload_json']===null?null:json_decode($part['payload_json'],true,64,JSON_THROW_ON_ERROR);
            if(str_starts_with($key,'d/')) {
                $date=substr($key,2);
                if(!isset($daySeen[$date]))foreach(cloudPartSyncDay($db,$uid,$date,$meta,$uploadID) as $seenDate)$daySeen[$seenDate]=true;
            }
            else {
                $old=cloudPartGet($db,$uid,$key);
                if($value===null) {
                    if(!empty($old['result']) && !isset($blocked[strtolower($old['id'])]))fail('已保存分析需要明确删除后才能移除。',400);
                    cloudPartDelete($db,$uid,$key);continue;
                }
                if(cloudPartJobKey((string)($value['id']??''))!==$key)fail('分析记录编号不一致。');
                $small=cloudPreserveAIRecords([...$meta,'aiJobs'=>[$value]],[...$meta,'aiJobs'=>$old?[$old]:[]]);
                $small=cloudPreservePlanExplanations([...$small,'days'=>[]],[...$meta,'days'=>[],'aiJobs'=>$old?[$old]:[]]);
                if(!$small['aiJobs']){cloudPartDelete($db,$uid,$key);continue;}
                cloudValidate($small['aiJobs'][0],'job');
                if(!cloudScheduleProposalsValid(['aiJobs'=>[$small['aiJobs'][0]]])) fail('日程提案格式不正确，原记录已保留。',400);
                $job=$small['aiJobs'][0];$job['request']['payload']=(object)$job['request']['payload'];cloudPartPut($db,$uid,$key,$job);
            }
        }
        foreach(array_keys($blocked) as $id)cloudPartDelete($db,$uid,cloudPartJobKey($id));
        // Explicit attachment tombstones also clear references in old date parts.
        // Tombstones are append-only on the client. Do not re-scan every old
        // tombstone on every commit; batch-check which ids are already deleted
        // and only revisit ids that are still referenced by a day part.
        $tombstones=[];
        foreach($meta['deletedMediaIDs']??[] as $media)$tombstones[mediaId($media)]=true;
        $knownTombstones=[];$referencedTombstones=[];
        foreach(array_chunk(array_keys($tombstones),400) as $chunk) {
            $marks=implode(',',array_fill(0,count($chunk),'?'));
            $rows=cloudPartQuery($db,"SELECT media_id FROM deleted_media WHERE user_id=? AND media_id IN ($marks)",array_merge([$uid],$chunk))->fetchAll(PDO::FETCH_COLUMN);
            foreach($rows as $known)$knownTombstones[$known]=true;
            $rows=cloudPartQuery($db,"SELECT DISTINCT media_id FROM cloud_media_refs WHERE user_id=? AND media_id IN ($marks)",array_merge([$uid],$chunk))->fetchAll(PDO::FETCH_COLUMN);
            foreach($rows as $referenced)$referencedTombstones[$referenced]=true;
        }
        foreach(array_keys($tombstones) as $id) {
            // Already deleted and unreferenced: cleanup was enqueued when first
            // seen and owns its own retry, so replaying the day parts is wasted.
            if(isset($knownTombstones[$id]) && !isset($referencedTombstones[$id])) continue;
            $dates=cloudPartQuery($db,'SELECT date_key FROM cloud_media_refs WHERE user_id=? AND media_id=?',[$uid,$id])->fetchAll(PDO::FETCH_COLUMN);
            foreach($dates as $date) {
                $day=cloudPartGet($db,$uid,'d/'.$date);if(!$day)continue;
                foreach($day['meals'] as &$meal)foreach(['photoFilename','photoRemoteID'] as $field)if(strtolower($meal[$field]??'')===$id)unset($meal[$field]);unset($meal);cloudPartPut($db,$uid,'d/'.$date,$day);
            }
            $insert=cloudPartQuery($db,'INSERT IGNORE INTO deleted_media(user_id,media_id,deleted_at) VALUES(?,?,UTC_TIMESTAMP())',[$uid,$id]);
            cloudPartQuery($db,'DELETE FROM user_media WHERE user_id=? AND media_id=?',[$uid,$id]);
            $mediaDirectory=dirname(__DIR__).'/media/'.$uid;
            if($insert->rowCount()>0 || mediaStoreResolve($mediaDirectory,$id)!==null || mediaStoreFiles($mediaDirectory,$id)!==[])enqueueMediaCleanup($db,$uid,$id);
        }
        // Same account lock/transaction as the uploaded parts: legacy metadata cannot create a second profile authority.
        if (is_array($meta['profile'] ?? null)) {
            profileFactsImportLegacyProfile($db,$uid,$meta['profile'],'legacy_recorded','cloud_sync');
            $document=profileFactsRead($db,$uid,true);
            $meta['profile']=profileFactsOverlayStateProfile($meta['profile'],$document['facts']);
        }
        cloudPartPut($db,$uid,'meta',$meta);$next=$current+1;
        $raw=json_encode(cloudPartMetadata($meta),JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
        cloudPartQuery($db,'INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE revision=VALUES(revision),state_json=VALUES(state_json),updated_at=VALUES(updated_at)',[$uid,$next,$raw]);
        cloudPartQuery($db,"UPDATE cloud_uploads SET status='committed',committed_revision=?,updated_at=UTC_TIMESTAMP() WHERE id=?",[$next,$uploadID]);
        cloudPartQuery($db,'DELETE FROM cloud_upload_parts WHERE upload_id=?',[$uploadID]);$db->commit();
    } catch(Throwable $e) {if($db->inTransaction())$db->rollBack();throw $e;}
    finally {flock($lock,LOCK_UN);fclose($lock);}
    // Media cleanup must not run while the per-database commit lock is held:
    // otherwise one slow attachment cleanup blocks every user's sync commit.
    return ['revision'=>$next,'media_cleanup_pending'=>processMediaCleanup($db,$uid)];
}
function cloudPartRoutes(PDO $db,array $config,string $method,string $path): void {
    if(!str_starts_with($path,'/me/sync'))return;
    $user=authenticated($db);$uid=(int)$user['id'];cloudPartEnsure($db,$uid);
    if($method==='GET' && $path==='/me/sync') {
        $db->beginTransaction();$revision=cloudPartRevision($db,$uid);
        if(isset($_GET['revision']) && (int)$_GET['revision']!==$revision){$db->rollBack();respond(409,['error'=>'云端已更新，请重新读取。']);}
        if(isset($_GET['known_revision']) && (int)$_GET['known_revision']===$revision){$db->commit();respond(200,['revision'=>$revision,'unchanged'=>true]);}
        $after=(string)($_GET['after']??'');if($after!==''&&!cloudPartKey($after))fail('分页标识不正确。');
        $rows=cloudPartQuery($db,'SELECT part_key AS `key`,content_hash AS hash,byte_size AS bytes FROM cloud_parts WHERE user_id=? AND part_key>? ORDER BY part_key LIMIT 501',[$uid,$after])->fetchAll();
        $more=count($rows)>500;if($more)array_pop($rows);$db->commit();
        respond(200,['revision'=>$revision,'parts'=>$rows,'next'=>$more?$rows[count($rows)-1]['key']:null]);
    }
    if($method==='POST' && $path==='/me/sync/read') {
        $input=body(65536);$keys=$input['keys']??[];
        if(!is_array($keys)||!array_is_list($keys)||count($keys)>64||!is_int($input['revision']??null))fail('分批读取请求不正确。');
        $db->beginTransaction();cloudPartAssertRevision($db,$uid,$input['revision']);$items=[];$bytes=0;
        foreach($keys as $key) {
            if(!is_string($key)||!cloudPartKey($key))fail('记录标识不正确。');
            $row=cloudPartQuery($db,'SELECT payload_json,content_hash FROM cloud_parts WHERE user_id=? AND part_key=?',[$uid,$key])->fetch();
            if(!$row){$db->rollBack();respond(409,['error'=>'记录目录已更新，请重新读取。']);}
            if($items && $bytes+strlen($row['payload_json'])>CLOUD_PAGE_BYTES)break;
            $items[]=['key'=>$key,'json'=>$row['payload_json'],'hash'=>$row['content_hash']];$bytes+=strlen($row['payload_json']);
        }
        $db->commit();respond(200,['revision'=>$input['revision'],'parts'=>$items]);
    }
    if($method==='POST' && $path==='/me/sync/uploads') {
        $input=body(65536);$base=$input['base_revision']??null;$count=$input['part_count']??null;
        if(!is_int($base)||$base<0||!is_int($count)||$count<0||$count>2147483647)fail('同步版本或分块数量不正确。');
        cloudPartAssertRevision($db,$uid,$base);
        cloudPartQuery($db,'DELETE FROM cloud_uploads WHERE user_id=? AND updated_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY)',[$uid]);
        $id=$input['id']??'';if(!is_string($id)||preg_match('/^[a-f0-9-]{36}$/Di',$id)!==1)fail('上传编号不正确。');
        $old=cloudPartQuery($db,'SELECT user_id,base_revision,expected_parts FROM cloud_uploads WHERE id=?',[$id])->fetch();
        if($old && ((int)$old['user_id']!==$uid || (int)$old['base_revision']!==$base || (int)$old['expected_parts']!==$count))fail('上传编号已使用。',409);
        cloudPartQuery($db,'INSERT IGNORE INTO cloud_uploads(id,user_id,base_revision,expected_parts,updated_at) VALUES(?,?,?,?,UTC_TIMESTAMP())',[$id,$uid,$base,$count]);respond(200,['id'=>$id]);
    }
    if(preg_match('#^/me/sync/uploads/([a-f0-9-]{36})(/commit)?$#Di',$path,$match) && $method==='POST') {
        $id=$match[1];if(!empty($match[2]))respond(200,cloudPartCommit($db,$uid,$id));
        $input=body(8*1024*1024);$parts=$input['parts']??null;if(!is_array($parts)||!array_is_list($parts)||count($parts)>64)fail('分批上传格式不正确。');
        $db->beginTransaction();lockActiveUser($db,$uid);
        $upload=cloudPartQuery($db,'SELECT status FROM cloud_uploads WHERE id=? AND user_id=? FOR UPDATE',[$id,$uid])->fetch();
        if(!$upload||$upload['status']!=='uploading')fail('上传已结束或过期，请重新同步。',410);
        foreach($parts as $part) {
            $key=$part['key']??'';$value=$part['value']??null;
            if(!is_string($key)||!cloudPartKey($key)||($value!==null&&!is_array($value)))fail('记录分块格式不正确。');
            if(str_starts_with($key,'d/')&&!cloudDateValid(substr($key,2)))fail('记录日期不正确。');
            $raw=$value===null?null:json_encode($value,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
            if($raw!==null && strlen($raw)>CLOUD_PART_BYTES)fail('单条记录超过4MiB，原记录保留。',413);
            cloudPartQuery($db,'INSERT INTO cloud_upload_parts(upload_id,part_key,payload_json) VALUES(?,?,?) ON DUPLICATE KEY UPDATE payload_json=VALUES(payload_json)',[$id,$key,$raw]);
            if(str_starts_with($key,'d/')) {
                $date=substr($key,2);cloudPartQuery($db,'DELETE FROM cloud_upload_meal_sources WHERE upload_id=? AND date_key=?',[$id,$date]);
                foreach($value['meals']??[] as $meal)if(!empty($meal['sourceAIJobID']) && is_string($meal['sourceAIJobID']))cloudPartQuery($db,'INSERT IGNORE INTO cloud_upload_meal_sources(upload_id,source_hash,date_key) VALUES(?,?,?)',[$id,hash('sha256',$meal['sourceAIJobID']),$date]);
            }
        }
        cloudPartQuery($db,'UPDATE cloud_uploads SET updated_at=UTC_TIMESTAMP() WHERE id=?',[$id]);$db->commit();respond(200,['accepted'=>count($parts)]);
    }
    fail('同步接口不存在。',404);
}
