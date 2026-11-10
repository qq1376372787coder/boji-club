<?php
declare(strict_types=1);
/** New confirmed plan versions compensate earlier changes; never restore a DB snapshot. */
function actionCompHash(mixed $value): string {
    return hash('sha256',json_encode(is_array($value)?aiProposalKeySort($value):$value,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR));
}
function actionCompMemories(PDO $db,int $uid): array {
    $q=$db->prepare("SELECT memory_id,idempotency_key,kind,status,origin,content,confidence,evidence_json,source_revision FROM user_memory_items WHERE user_id=? AND kind='preference'".($db->inTransaction()?' FOR UPDATE':''));
    $q->execute([$uid]);$out=[];
    foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){$row['confidence']=(int)$row['confidence'];$row['source_revision']=$row['source_revision']===null?null:(int)$row['source_revision'];$out[$row['idempotency_key']]=$row;}
    return $out;
}
function actionCompTemplates(array $state): array {
    $out=[];foreach($state['planTemplates']??[] as $template)$out[strtolower($template['id'])]=$template;return $out;
}
function actionCapturePlanInverse(PDO $db,int $uid,array $before,array $after,array $dates,array $beforeMemory): array {
    $sessions=[];$hashes=[];
    foreach($dates as $date){
        $exercises=[];foreach(actionExerciseTargets($before['days'][$date]['exercises']??[]) as $exercise){$value=aiPlannedExerciseValid($exercise);if($value===null)throw new RuntimeException('original_plan_targets_invalid');$exercises[]=$value;}
        $sessions[]=['date'=>$date,'label'=>'恢复此前安排','exercises'=>$exercises];
        $hashes[$date]=businessDayFingerprint($after['days'][$date]??[]);
    }
    $templates=[];$a=actionCompTemplates($before);$b=actionCompTemplates($after);
    foreach(array_unique(array_merge(array_keys($a),array_keys($b))) as $id)if(actionCompHash($a[$id]??null)!==actionCompHash($b[$id]??null))$templates[$id]=['before'=>$a[$id]??null,'after_hash'=>actionCompHash($b[$id]??null)];
    $memories=[];$current=actionCompMemories($db,$uid);
    foreach(array_unique(array_merge(array_keys($beforeMemory),array_keys($current))) as $key)if(actionCompHash($beforeMemory[$key]??null)!==actionCompHash($current[$key]??null))$memories[$key]=['before'=>$beforeMemory[$key]??null,'after_hash'=>actionCompHash($current[$key]??null)];
    return ['version'=>1,'plan_inverse'=>['sessions'=>$sessions,'after_days'=>$hashes,'templates'=>$templates,'memories'=>$memories]];
}
function actionPlanInverse(PDO $db,int $uid,string $command): array {
    $q=$db->prepare("SELECT undo_json FROM data_operations WHERE user_id=? AND operation_id=? AND command_type='PlanVersion.Activate' AND status='succeeded'");$q->execute([$uid,$command]);
    $value=json_decode((string)$q->fetchColumn(),true)['plan_inverse']??null;
    if(!is_array($value)||empty($value['sessions'])||empty($value['after_days']))fail('这条旧变更缺少可安全恢复的依据，请按当前安排重新预览。',409);
    return $value;
}
function actionPlanCompensationSessions(PDO $db,int $uid,array $state,array $inverse,?string $keep): array {
    $sessions=[];$retained=[];$today=actionToday($db,$uid);
    if($keep!==null&&!in_array($keep,array_column($inverse['sessions'],'date'),true))fail('要保留的日期不在这次原变更范围，请重新选择。',409);
    foreach($inverse['sessions'] as $session){
        $date=$session['date'];$day=$state['days'][$date]??[];
        if($date<$today||$date===$keep||businessDayProtected($day)){$retained[]=$date;continue;}
        if(!hash_equals($inverse['after_days'][$date]??'',businessDayFingerprint($day)))fail('后续安排已修改，不能用旧变更覆盖，请重新选择需要恢复的日期。',409);
        $sessions[]=$session;
    }
    if(!$sessions)fail('没有可安全补偿的未开始安排；已开始或完成的训练会保留。',409);
    return [$sessions,$retained];
}
function actionValidatePlanCompensation(PDO $db,int $uid,array $state,array $payload): array {
    $inverse=actionPlanInverse($db,$uid,$payload['compensates']);
    [$expected,$retained]=actionPlanCompensationSessions($db,$uid,$state,$inverse,$payload['keep_date']??null);
    if(actionCompHash($expected)!==actionCompHash($payload['sessions'])||$retained!==$payload['retained_dates'])fail('补偿范围已变化，请重新预览。',409);
    $templates=actionCompTemplates($state);
    foreach($inverse['templates']??[] as $id=>$change)if(!hash_equals($change['after_hash'],actionCompHash($templates[$id]??null)))fail('每周模板后来已修改，不能自动覆盖。',409);
    $memories=actionCompMemories($db,$uid);
    foreach($inverse['memories']??[] as $key=>$change)if(!hash_equals($change['after_hash'],actionCompHash($memories[$key]??null)))fail('相关偏好后来已修改，不能自动覆盖。',409);
    return $inverse;
}
function actionApplyPlanCompensation(PDO $db,int $uid,array &$state,array $inverse,string $proposal,int $revision): void {
    foreach($inverse['templates']??[] as $id=>$change){
        $state['planTemplates']=array_values(array_filter($state['planTemplates']??[],fn($t)=>strtolower($t['id'])!==$id));
        $state['deletedPlanTemplateIDs']=array_values(array_unique(array_merge($state['deletedPlanTemplateIDs']??[],[$id])));
        if(is_array($change['before'])){
            $restored=$change['before'];$newID=actionUUID('compensated-template/'.$proposal.'/'.$id);
            $restored['id']=$newID;$restored['createdAt']=businessDocumentNow();$restored['draft']['id']=$newID;$restored['updatedAt']=businessDocumentNow();$restored['draft']['updatedAt']=businessDocumentNow();
            cloudValidate($restored,'planTemplate','compensatedTemplate');$state['planTemplates'][]=$restored;
        }
    }
    foreach($inverse['memories']??[] as $key=>$change){
        $old=$change['before'];
        if($old===null){$db->prepare("UPDATE user_memory_items SET status='suspended',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND idempotency_key=?")->execute([$uid,$key]);}
        else{$db->prepare('UPDATE user_memory_items SET status=?,origin=?,content=?,confidence=?,evidence_json=?,source_revision=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND idempotency_key=?')->execute([$old['status'],$old['origin'],$old['content'],$old['confidence'],$old['evidence_json'],$revision,$uid,$key]);}
    }
}

/** A new explicit weekly-plan confirmation supersedes only system-owned patterns. */
function actionRememberRecurringPlan(PDO $db,int $uid,array $payload,string $proposal,int $revision): void {
    require_once __DIR__.'/ai-memory.php';
    $weekday=(int)$payload['recurring_weekday'];
    $prefix='已确认每周'.$weekday.'采用';
    foreach(actionCompMemories($db,$uid) as $row){
        if($row['origin']==='extracted'&&$row['status']==='active'&&str_starts_with($row['content'],$prefix)){
            $evidence=json_decode($row['evidence_json'],true)?:[];
            if(array_filter($evidence,fn($e)=>($e['type']??'')==='action_proposal'))$db->prepare("UPDATE user_memory_items SET status='suspended',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND memory_id=?")->execute([$uid,$row['memory_id']]);
        }
    }
    aiMemoryUpsert($db,$uid,'preference',$prefix.'「'.$payload['title'].'」的训练安排；后续周期生成时请参考这项偏好。',100,[['type'=>'action_proposal','id'=>$proposal]],'recurring-plan-weekday-'.$weekday.'/plan/'.$payload['draft_id'],$revision);
}
