<?php
declare(strict_types=1);
require_once __DIR__.'/action-support.php';
require_once __DIR__.'/app-config.php';

/** Stable operation identity belongs to a message/call, not to its numeric contents. */
function actionCallIdentity(int $uid,string $message,int $index,string $capability): string {
 return actionUUID('call/'.$uid.'/'.$message.'/'.$index.'/'.$capability);
}
function actionResultStatus(string $status): string {
 return match($status){'succeeded','committed','draft_ready'=>'completed','executing','processing','dispatching','pending'=>'running',default=>$status};
}
function aiRouterStatusEnvelope(array $data,string $id): array {
 $data['status']=actionResultStatus((string)($data['status']??'running'));
 if(isset($data['capability'])||isset($data['card']))return ['execution_id'=>$id]+$data;
 return ['execution_id'=>$id,'status'=>$data['status'],'proposal_id'=>$data['proposal_id']??null,'data'=>$data];
}
function actionCallAdvance(PDO $db,int $uid,string $id,string $status,?array $result=null): void {
 $q=$db->prepare('SELECT lifecycle_json FROM ai_action_calls WHERE user_id=? AND call_id=?');$q->execute([$uid,$id]);
 $history=json_decode((string)$q->fetchColumn(),true)?:[];
 $history[]=['state'=>$status,'at'=>gmdate('c'),'actor'=>'server'];
 $db->prepare('UPDATE ai_action_calls SET status=?,result_json=COALESCE(?,result_json),lifecycle_json=?,lease_until=NULL,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND call_id=?')
 ->execute([$status,$result===null?null:json_encode($result,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),json_encode($history),$uid,$id]);
}
function actionCallResolve(PDO $db,array $user,array $call,string $message,int $index,?string $conversation): array {
 $uid=(int)$user['id'];$cap=(string)($call['capability']??'');$id=actionCallIdentity($uid,$message,$index,$cap);
 $parentTrace=$db->prepare('SELECT trace_id FROM ai_action_messages WHERE user_id=? AND message_id=?');
 $parentTrace->execute([$uid,$message]);$trace=(string)($parentTrace->fetchColumn()?:($GLOBALS['boji_trace_id']??''));
 if($trace!=='')$GLOBALS['boji_trace_id']=$trace;
 // A cancelled/failed parent run must not execute uncommitted child actions.
 $parent=$db->prepare("SELECT status FROM ai_runs WHERE user_id=? AND message_id=? ORDER BY created_at DESC LIMIT 1");
 $parent->execute([$uid,$message]);$parentStatus=(string)($parent->fetchColumn()?:'');
 if(in_array($parentStatus,['cancelled','failed'],true))return ['capability'=>$cap,'execution_id'=>$id,'status'=>'cancelled','error'=>'该消息已取消，未执行任何后续操作。'];
 $input=$call['input']??[];$hash=hash('sha256',json_encode(aiProposalKeySort(is_array($input)?$input:[]),JSON_UNESCAPED_UNICODE));
 $db->beginTransaction();
 try{
  lockActiveUser($db,$uid);
  actionAssertParentActive($db,$uid);
  $q=$db->prepare('SELECT input_hash,status,result_json,lease_until FROM ai_action_calls WHERE user_id=? AND call_id=? FOR UPDATE');$q->execute([$uid,$id]);$old=$q->fetch(PDO::FETCH_ASSOC);
  if($old){
   if(!hash_equals($old['input_hash'],$hash))businessReject(409,['error'=>'同一行动编号不能替换参数。']);
   $saved=json_decode((string)$old['result_json'],true);
   if(is_array($saved)){$db->commit();return actionRefreshResult($db,$uid,$saved);}
   if($old['lease_until']&&strtotime($old['lease_until'].' UTC')>time()){$db->commit();return ['capability'=>$cap,'execution_id'=>$id,'status'=>'verifying_result'];}
   $db->prepare("UPDATE ai_action_calls SET lease_until=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 90 SECOND),updated_at=UTC_TIMESTAMP() WHERE user_id=? AND call_id=?")->execute([$uid,$id]);
  }else{
   $history=[['state'=>'received','at'=>gmdate('c'),'actor'=>'user']];
   $db->prepare("INSERT INTO ai_action_calls(user_id,call_id,message_id,conversation_id,trace_id,capability,input_hash,input_json,status,lifecycle_json,lease_until,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,'received',?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 90 SECOND),UTC_TIMESTAMP(),UTC_TIMESTAMP())")
   ->execute([$uid,$id,$message,$conversation,$trace!==''?$trace:null,$cap,$hash,json_encode($input),json_encode($history)]);
  }
  $db->commit();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
 try{
  // The persisted ID fences retries, including a crash after the domain transaction.
  $call['_action_id']=$id;$call['_conversation_id']=$conversation;
  $result=actionWithParent($uid,$message,fn()=>businessScoped(fn()=>aiRouterRouteOne($db,$user,$call)));$result['execution_id']=$id;
  if(isset($result['job_id']))$result['data']['job_id']=$result['job_id'];
  actionCallAdvance($db,$uid,$id,$result['status'],$result);return $result;
 }catch(Throwable $e){
  if($db->inTransaction())$db->rollBack();
  $code=$e instanceof RuntimeException?$e->getCode():500;
  $cancelled=$e instanceof BusinessActionError && ($e->detail['code']??'')==='PARENT_RUN_CANCELLED';
  $result=['capability'=>$cap,'execution_id'=>$id,'status'=>$cancelled?'cancelled':($code===409?'conflict':($code>=500?'failed_retryable':'rejected')),'error'=>$code>=500?'服务暂不可用，可按原行动编号重试。':$e->getMessage()];
  // Retryable failures are not cached as terminal results.
  actionCallAdvance($db,$uid,$id,$result['status'],$code>=500?null:$result);return $result;
 }
}
function actionRefreshResult(PDO $db,int $uid,array $result): array {
 if(!empty($result['proposal_id'])){
  aiProposalExpireDue($db,$uid);$p=aiProposalFetch($db,$uid,$result['proposal_id']);
  if($p){$result['status']=actionResultStatus($p['status']);if($result['status']==='completed'&&in_array($p['kind'],['weight_entry','meal_draft'],true))$result['data']['commandId']=$p['confirmed_command_id'];if($result['status']!=='awaiting_confirmation'&&isset($result['card']))$result['card']['actions']=[];}
 }
 if(!empty($result['data']['commandId'])){
  $q=$db->prepare("SELECT operation_id FROM data_operations WHERE user_id=? AND command_type='Action.Undo' AND aggregate_id=? LIMIT 1");$q->execute([$uid,$result['data']['commandId']]);
  if($q->fetchColumn()){$result['status']='undone';if(isset($result['card']))$result['card']['actions']=[];}
 }
 if(!empty($result['job_id'])){
  $q=$db->prepare('SELECT status FROM ai_action_jobs WHERE user_id=? AND execution_id=?');$q->execute([$uid,$result['job_id']]);$s=$q->fetchColumn();if($s!==false)$result['status']=actionResultStatus($s);
 }
 return $result;
}
/** Explicit user confirmation endpoints are not part of the model whitelist. */
function actionConfirmProposal(PDO $db,array $user,string $id): array {
 if(!appFeatureEnabled($db,'action_system_enabled'))fail('AI 行动已暂停，提案与记录仍保留。',503);
 return businessScoped(function()use($db,$user,$id){
  $p=aiProposalFetch($db,(int)$user['id'],$id);if(!$p)fail('提案不存在。',404);
  if(!empty($p['trace_id']))$GLOBALS['boji_trace_id']=(string)$p['trace_id'];
  $types=['plan_change_proposal'=>'PlanReschedule.Confirm','exercise_swap'=>'ExerciseSwap.Confirm','plan_activation'=>'PlanVersion.Activate','meal_draft'=>'Meal.Create','weight_entry'=>'BodyWeight.Create','training_finish'=>'Training.FinishConfirm'];
  if(!isset($types[$p['kind']]))fail('提案类型不支持。',422);
  return handleBusinessCommandCore($db,$user,['commandId'=>actionUUID('confirm/'.$user['id'].'/'.$id),'type'=>$types[$p['kind']],'payload'=>['proposalId'=>$id],'actor'=>'user']);
 });
}

/** A model result can execute only for a message accepted before its AI request. */
function actionResolveCompletedMessage(PDO $db,array $user,string $id,array $response): array {
 return actionWithParent((int)$user['id'],$id,fn()=>actionResolveCompletedMessageFenced($db,$user,$id,$response));
}
function actionResolveCompletedMessageFenced(PDO $db,array $user,string $id,array $response): array {
 $empty=['results'=>[]];
 if(($response['status']??'')!=='succeeded')return $empty;
 $calls=$response['result']['coach']['capability_calls']??[];if(!$calls)return $empty;
 if(!appFeatureEnabled($db,'action_system_enabled'))return ['results'=>array_map(fn($c)=>['capability'=>$c['capability']??null,'status'=>'rejected','error'=>'AI 行动已暂停，未执行操作。'],$calls)];
 // P2 休眠：coach 消息的能力执行同样停用。已提交的对话结果保留，但不再产生
 // 任何业务写入；开关打开后（coach_enabled=true）恢复原执行路径。
 if(!coachEnabled($db))return ['results'=>array_map(fn($c)=>['capability'=>$c['capability']??null,'status'=>'rejected','error'=>'AI 对话功能暂未开放，未执行操作。'],$calls)];
 $parent=$db->prepare("SELECT status FROM ai_runs WHERE user_id=? AND message_id=? ORDER BY created_at DESC LIMIT 1");
 $parent->execute([(int)$user['id'],$id]);$parentStatus=(string)($parent->fetchColumn()?:'');
 if(in_array($parentStatus,['cancelled','failed'],true))return $empty;
 $q=$db->prepare("SELECT conversation_id,status FROM ai_action_messages WHERE user_id=? AND message_id=?");$q->execute([$user['id'],$id]);$row=$q->fetch(PDO::FETCH_ASSOC);
 if(!$row)throw new RuntimeException('action_message_missing');
 if($row['status']!=='accepted')return actionMessageResults($db,(int)$user['id'],$id);
 // Purpose is server-owned. An onboarding run may only execute the same
 // read-only subset that was exposed to the model, even if a manipulated
 // provider response contains other capability names.
 $purposeQuery=$db->prepare("SELECT request_json FROM ai_runs WHERE user_id=? AND message_id=? ORDER BY created_at DESC LIMIT 1");
 $purposeQuery->execute([(int)$user['id'],$id]);$storedRequest=json_decode((string)($purposeQuery->fetchColumn()?:''),true);
 // Local snapshots are read-only even if a provider emits a forged mutation.
 if(is_array($storedRequest)&&!empty($storedRequest['payload']['context_bundle_id'])){
  global $config;require_once __DIR__.'/ai-context.php';
  $bundle=aiContextLoad($db,(int)$user['id'],(string)$storedRequest['payload']['context_bundle_id'],(string)($storedRequest['payload']['conversation_id']??$row['conversation_id']),$config);
  if(localContextIsReadOnly131($bundle['references']))return $empty;
 }
 if(is_array($storedRequest)&&($storedRequest['payload']['purpose']??'')==='onboarding_assist'){
  $allowed=array_column(function_exists('onboardingCapabilityWhitelist')?onboardingCapabilityWhitelist():[],'capability');
  $calls=array_values(array_filter($calls,fn($call)=>is_array($call)&&in_array($call['capability']??'', $allowed, true)));
  if(!$calls)return $empty;
 }
 $questionQuery=$db->prepare("SELECT content FROM ai_messages WHERE user_id=? AND job_client_id=? AND role='user' LIMIT 1");$questionQuery->execute([(int)$user['id'],$id]);$userText=(string)($questionQuery->fetchColumn()?:'');
 foreach($calls as &$call)$call['_user_text']=$userText;unset($call);
 $resolved=aiRouterResolve($db,$user,['message_id'=>$id,'conversation_id'=>$row['conversation_id'],'calls'=>$calls]);
 if(!array_filter($resolved['results'],fn($r)=>in_array($r['status'],['failed_retryable','verifying_result'],true))){
  // Settling the parent is fenced too: an old worker must not mark a new
  // owner's unexecuted message resolved after its child claim was rejected.
  $db->beginTransaction();
  try{lockActiveUser($db,(int)$user['id']);actionAssertParentActive($db,(int)$user['id']);
   $db->prepare("UPDATE ai_action_messages SET status='resolved',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND message_id=? AND status='accepted'")->execute([$user['id'],$id]);$db->commit();
  }catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
 }
 // Calls remain independently resumable if a later child or the response fails.
 return $resolved;
}
function actionMessageResults(PDO $db,int $uid,string $id): array {
 $q=$db->prepare('SELECT result_json,status,call_id,capability FROM ai_action_calls WHERE user_id=? AND message_id=? ORDER BY created_at,call_id');$q->execute([$uid,$id]);$results=[];
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){$r=json_decode((string)$row['result_json'],true)??['capability'=>$row['capability'],'execution_id'=>$row['call_id'],'status'=>'verifying_result'];$results[]=actionRefreshResult($db,$uid,$r);}
 if(!$results){
  $run=$db->prepare("SELECT result_json FROM ai_runs WHERE user_id=? AND message_id=? AND status='completed' LIMIT 1");$run->execute([$uid,$id]);$saved=json_decode((string)($run->fetchColumn()?:''),true);
  if(is_array($saved['coach']['action_results']??null))$results=$saved['coach']['action_results'];
  elseif(!empty($saved['coach']['capability_calls']))$results=array_map(fn($c)=>['capability'=>$c['capability']??null,'status'=>'rejected','error'=>'旧消息没有业务执行回执，不能视为已执行。请核对记录后明确重新发起操作。'],$saved['coach']['capability_calls']);
 }
 return ['results'=>$results];
}

function actionDiscardTraining(PDO $db,array $user,string $proposal): array {
 return businessScoped(fn()=>handleBusinessCommandCore($db,$user,['commandId'=>actionUUID('discard/'.$user['id'].'/'.$proposal),'type'=>'Training.DiscardConfirm','payload'=>['proposalId'=>$proposal],'actor'=>'user']));
}

/** Editing a meal draft replaces the preview atomically; the original can no longer be committed. */
function actionEditMealDraft(PDO $db,array $user,string $id,array $body): array {
 return businessScoped(function()use($db,$user,$id,$body){
  $uid=(int)$user['id'];$edit=$body['edit_id']??'';
  if(!trainingSessionIDValid($edit))fail('缺少稳定的编辑编号。',422);
  $payload=aiProposalPayloadValid('meal_draft',$body['payload']??null);if(!$payload||$payload['date']>actionToday($db,$uid))fail('饮食草稿内容不正确。',422);
  $key=hash('sha256','meal-edit/'.$uid.'/'.$id.'/'.$edit);
  $db->beginTransaction();
  try {
   lockActiveUser($db,$uid);
   $q=$db->prepare('SELECT * FROM ai_action_proposals WHERE user_id=? AND proposal_id=? FOR UPDATE');$q->execute([$uid,$id]);$old=$q->fetch(PDO::FETCH_ASSOC);
   if(!$old||$old['kind']!=='meal_draft')fail('饮食草稿不存在。',404);
   $q=$db->prepare('SELECT proposal_id FROM ai_action_proposals WHERE user_id=? AND idempotency_key=?');$q->execute([$uid,$key]);$already=$q->fetchColumn();
   if(!$already&&($old['status']!=='awaiting_confirmation'||strtotime($old['expires_at'].' UTC')<=time()))fail('草稿已变化或过期，请重新读取。',409);
   $created=aiProposalCreate($db,$uid,'meal_draft',$payload,[],null,$key);
   $db->prepare("UPDATE ai_action_proposals SET status='cancelled',updated_at=UTC_TIMESTAMP() WHERE user_id=? AND proposal_id=? AND status='awaiting_confirmation'")->execute([$uid,$id]);
   $preview=$payload+['proposal_id'=>$created['proposal_id'],'kind'=>'meal_draft','preview'=>$payload,'expires_at'=>actionISO($created['expires_at'])];
   $result=['capability'=>'nutrition.create_draft','status'=>actionResultStatus($created['status']),'proposal_id'=>$created['proposal_id'],'card'=>aiRouterCard(['card_type'=>'meal_draft','title'=>'已编辑的饮食草稿','payload'=>$preview,'actions'=>[['action_id'=>'confirm_proposal','label'=>'确认保存','kind'=>'confirm'],['action_id'=>'dismiss_proposal','label'=>'不采用','kind'=>'dismiss']]],'proposal/'.$created['proposal_id'],$created['expires_at'])];
   $q=$db->prepare('SELECT call_id,result_json FROM ai_action_calls WHERE user_id=? AND result_json IS NOT NULL');$q->execute([$uid]);
   foreach($q->fetchAll(PDO::FETCH_ASSOC) as $call){$prior=json_decode($call['result_json'],true);if(($prior['proposal_id']??null)===$id){$result['execution_id']=$call['call_id'];$db->prepare('UPDATE ai_action_calls SET result_json=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND call_id=?')->execute([json_encode($result,JSON_UNESCAPED_UNICODE),$uid,$call['call_id']]);}}
   $db->commit();return $result;
  }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
 });
}
