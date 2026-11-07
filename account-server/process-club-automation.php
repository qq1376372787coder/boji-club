<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli')exit(1);
require __DIR__.'/public/automation.php';
require __DIR__.'/public/cloud-parts.php';
require __DIR__.'/public/ai-response.php';
$config=require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
$lockPath=sys_get_temp_dir().'/bojiclub-automation-'.substr(hash('sha256',(string)$db->query('SELECT DATABASE()')->fetchColumn()),0,16).'.lock';
$lock=fopen($lockPath,'c');if(!$lock||!flock($lock,LOCK_EX|LOCK_NB))exit(0);
// 有界重试：同一配置版本内连续失败达到上限后进入终态 failed，不再无限重试。
$retryLimit=clubAutomationRetryLimit($config);
// 上次异常退出遗留的“处理中”记录改为中断，避免统计长期挂起。
$db->exec("UPDATE club_automation_runs SET outcome='failed',error_summary='interrupted',finished_at=UTC_TIMESTAMP() WHERE outcome='running' AND started_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 10 MINUTE)");
// Rotate by next_run, not account creation; a slow or failing account cannot starve others.
// AUD-008：终态 failed 不再被 due 查询领取；用户保存配置（retry_count 清零）
// 或后台“手动重跑”后重新满足条件。仅靠 next_run 跨日并不够。
$batch=max(1,min(1000,(int)($config['automation_accounts_per_run']??100)));
$due=$db->query('SELECT user_id FROM club_automation WHERE enabled=1 AND paused=0 AND next_run<=UTC_TIMESTAMP() AND (COALESCE(last_status,\'\') NOT LIKE \'failed%\' OR retry_count < '.$retryLimit.') ORDER BY next_run,user_id LIMIT '.$batch)->fetchAll();
$deadline=microtime(true)+max(5,min(55,(int)($config['automation_run_seconds']??50)));
function clubAutomationHealthHasData(mixed $health): bool {
    if(!is_array($health))return false;
    if(!empty($health['workouts']))return true;
    foreach(['steps','activeEnergy','heartRate','restingHeartRate','sleep','bodyMass','bodyFatPercentage','leanBodyMass','height','bodyMassIndex','waistCircumference'] as $key)if(($health[$key]??null)!==null)return true;
    return false;
}
foreach($due as $item) {
    if(microtime(true)>$deadline)break;
    $uid=(int)$item['user_id'];
    $revision=0;$count=0;$attempts=0;$runId=0;
    // 每次处理写一条执行记录：业务任务（唯一 client_job）与供应商尝试分开计数，重试不算用户使用次数。
    try{$db->prepare("INSERT INTO club_automation_runs(user_id,revision,outcome,tasks_submitted,vendor_attempts,started_at,finished_at) VALUES(?,0,'running',0,0,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([$uid]);$runId=(int)$db->lastInsertId();}catch(Throwable){$runId=0;}
    $finish=function(string $outcome,string $summary='')use($db,$runId,&$revision,&$count,&$attempts):void {
        if(!$runId)return;
        try{$db->prepare('UPDATE club_automation_runs SET revision=?,outcome=?,tasks_submitted=?,vendor_attempts=?,error_summary=?,finished_at=UTC_TIMESTAMP() WHERE id=?')->execute([$revision,$outcome,$count,$attempts,$summary===''?null:mb_substr($summary,0,200),$runId]);}catch(Throwable){fwrite(STDERR,"Club automation run log deferred\n");}
    };
    try {
        $db->beginTransaction();
        $q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);
        if($q->fetchColumn()!=='active'){$db->prepare("UPDATE club_automation SET enabled=0,last_status='account_inactive' WHERE user_id=?")->execute([$uid]);$db->commit();$finish('skipped','account_inactive');continue;}
        $q=$db->prepare('SELECT * FROM club_automation WHERE user_id=? AND enabled=1 AND paused=0 FOR UPDATE');$q->execute([$uid]);$row=$q->fetch();
        if(!$row){$db->rollBack();$finish('skipped','settings_gone');continue;}
        $revision=(int)$row['revision'];
        $db->prepare('UPDATE club_automation SET next_run=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 MINUTE) WHERE user_id=?')->execute([$uid]);
        $q=$db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND status='active' AND expires_at>UTC_TIMESTAMP()");$q->execute([$uid]);
        if(!$q->fetchColumn()){$db->prepare("UPDATE club_automation SET last_status='membership_required' WHERE user_id=?")->execute([$uid]);$db->commit();$finish('skipped','membership_required');continue;}
        $settings=clubAutomationPreferences(json_decode($row['preferences_json'],true,32,JSON_THROW_ON_ERROR));
        $zone=new DateTimeZone($settings['zone']);$today=(new DateTimeImmutable('now',$zone))->format('Y-m-d');
        $first=(new DateTimeImmutable($today,$zone))->modify('-35 days')->format('Y-m-d');
        $state=cloudStoredState($db,$uid,$first,$today,true,true);
        $state['automationGoalBaseline']=clubAutomationGoalBaseline($db,$uid,$state,$first,$zone);
        $state['days']=array_filter($state['days']??[],fn($key)=>$key>=$first&&$key<=$today,ARRAY_FILTER_USE_KEY);
        // 应执行但跳过：近 35 天没有任何训练/饮食/体重/已确认分享的健康记录时不做空转分析（“无数据”）。
        // 健康数据与 Python 资格白名单保持一致；普通 day.health 仅包含用户确认分享的汇总。
        $hasData=false;
        foreach(($state['days']??[]) as $key=>$day)if(!empty($day['meals'])||!empty($day['exercises'])||!empty($day['workoutSessions'])||!empty($day['bodyWeight'])||clubAutomationHealthHasData($day['health']??null)){$hasData=true;break;}
        if(!$hasData){$db->prepare("UPDATE club_automation SET next_run=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 30 MINUTE),last_status='no_data',retry_count=0 WHERE user_id=? AND revision=?")->execute([$uid,$revision]);$db->commit();$finish('skipped','no_data');continue;}
        $coverage=[];$claims=json_decode($row['coverage_json'],true,32,JSON_THROW_ON_ERROR);
        foreach($claims as $key=>$claim) {
            $meals=$state['days'][$key]['meals']??[];
            $coverage[$key]=is_array($claim) && ($claim['complete']??false)===true && is_string($claim['fingerprint']??null) && hash_equals($claim['fingerprint'],clubAutomationMealFingerprint($meals));
        }
        // Never send identity fields, drafts, avatars, addresses, or full saved conversations.
        $state=array_intersect_key($state,array_flip(['days','aiJobs','automationGoalBaseline']));
        foreach(($state['days']??[]) as $key=>$day) {
            $clean=array_intersect_key($day,array_flip(['exercises','meals','workoutSessions','workoutStartedAt','workoutEndedAt','workoutSavedAt','health','linkedDeviceWorkoutID','bodyWeight','nutritionTarget','planCycle','goalVersions']));
            $clean['exercises']=array_map(fn($ex)=>array_intersect_key($ex,array_flip(['id','name','muscle','sets','workoutSessionID','libraryID','customExerciseID'])), $day['exercises']);
            $clean['meals']=array_map(fn($meal)=>array_intersect_key($meal,array_flip(['name','calories','protein','carbs','fat','nutritionKnown'])), $day['meals']);
            if(!empty($clean['goalVersions'])) {
                $clean['goalVersions']=array_map('clubAutomationGoal',$clean['goalVersions']);
            }
            $state['days'][$key]=$clean;
        }
        $q=$db->prepare('SELECT revision FROM app_states WHERE user_id=?');$q->execute([$uid]);$cloud=(int)($q->fetchColumn()?:0);
        $q=$db->prepare('SELECT client_job_id,server_job_id FROM ai_user_jobs WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY)');$q->execute([$uid]);
        $mapped=$q->fetchAll();$byServer=[];foreach($mapped as $m)$byServer[$m['server_job_id']]=$m['client_job_id'];
        // Release account locks before worker HTTP requests: saving records
        // must not wait for the analysis service or a network timeout.
        $db->commit();
        $known=[];$existingReports=[];
        foreach(array_chunk(array_keys($byServer),50) as $ids) {
            if(microtime(true)>$deadline){$finish('retry_pending','deadline');continue 2;}
            if(!clubAutomationCurrent($db,$uid,$revision)){$finish('skipped','revision_changed');continue 2;}
            $metadata=clubAutomationPrivate($config,'/v1/jobs/metadata',['ids'=>$ids]);
            foreach($metadata['items']??[] as $m)if(isset($byServer[$m['id']])) {
                $known[]=$byServer[$m['id']];
                // Map date→source revision (C07): a changed source needs a new report version, not a skip.
                if($m['kind']==='report' && !in_array($m['status'],['deleted','expired','discarded','rejected'],true))$existingReports[$m['date']]=$m['source_revision']??null;
            }
        }
        if(microtime(true)>$deadline){$finish('retry_pending','deadline');continue;}
        if(!clubAutomationCurrent($db,$uid,$revision)){$finish('skipped','revision_changed');continue;}
        $prepared=clubAutomationPrivate($config,'/v1/automation/prepare',['owner'=>$uid,'state'=>$state,'settings'=>$settings,'coverage'=>(object)$coverage,'coverage_current'=>true,'known_ids'=>$known,'existing_reports'=>$existingReports]);
        $abort='';
        foreach($prepared['items']??[] as $task) {
            if(microtime(true)>$deadline){$abort='deadline';break;}
            if(!clubAutomationCurrent($db,$uid,$revision)){$abort='revision_changed';break;}
            $client=$task['client_id'];$request=$task['request'];
            if(!preg_match('/^[a-f0-9-]{36}$/D',$client)||!in_array($request['kind']??'', ['report','coach'],true))throw new RuntimeException('invalid internal task');
            $server=clubAutomationServerID($uid,$client,$config);
            $q=$db->prepare('SELECT kind FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');$q->execute([$uid,$client]);$existing=$q->fetchColumn();
            if($existing && $existing!==$request['kind'])throw new RuntimeException('task identity conflict');
            $found=clubAutomationPrivate($config,'/v1/jobs/metadata',['ids'=>[$server]]);
            if($found['items']??[]) {
                // 业务任务按唯一 client_job 计数：补登记映射算一条业务任务，不算供应商尝试。
                if(!$existing){$db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE client_job_id=VALUES(client_job_id)')->execute([$uid,$client,$server,$request['kind']]);$count++;}
                continue;
            }
            // Reserve the deterministic mapping before acceptance, outside the
            // snapshot transaction. Uncertain responses are repaired next pass.
            $request['id']=$server;$request['_quota_owner']=aiQuotaOwner($uid,$config);
            if(!$existing)$db->prepare('INSERT INTO ai_user_jobs(user_id,client_job_id,server_job_id,kind,created_at) VALUES(?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE client_job_id=VALUES(client_job_id)')->execute([$uid,$client,$server,$request['kind']]);
            if(!clubAutomationCurrent($db,$uid,$revision)){$abort='revision_changed';break;}
            clubAutomationPrivate($config,'/v1/jobs',$request);
            $attempts++; // 供应商尝试：含修复重提，不计为用户使用次数
            if(!$existing)$count++; // 业务任务：只按唯一 client_job 首次提交计数
        }
        $final=$count?'submitted':(!empty($prepared['deferred'])?'needs_record_check':'checked');
        $db->prepare('UPDATE club_automation SET retry_count=0,last_status=? WHERE user_id=? AND revision=? AND enabled=1')->execute([$final,$uid,$revision]);
        if($abort==='deadline')$finish('retry_pending','deadline');
        elseif($abort==='revision_changed')$finish('skipped','revision_changed');
        else $finish($final);
    } catch(Throwable $error) {
        // Keep a reserved mapping even after an uncertain upstream response.
        // The next pass checks worker metadata and retries only missing jobs.
        if($db->inTransaction())$db->rollBack();
        // 有界重试：退避 5 分钟；达到上限进入终态 failed 并在 last_status 写清摘要。
        // 恢复路径：用户下次保存配置（retry_count 清零）或后台“手动重跑”。
        $summary=clubAutomationErrorSummary($error);
        $q=$db->prepare('SELECT retry_count FROM club_automation WHERE user_id=? AND revision=? AND enabled=1');$q->execute([$uid,$revision]);
        $failures=(int)($q->fetchColumn()?:0)+1;
        if(clubAutomationRetryDecision($failures,$retryLimit)==='failed') {
            $db->prepare("UPDATE club_automation SET retry_count=?,next_run=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY),last_status=? WHERE user_id=? AND revision=? AND enabled=1")->execute([$failures,'failed: '.mb_substr($summary,0,88),$uid,$revision]);
            $finish('failed',$summary);
        } else {
            $db->prepare("UPDATE club_automation SET retry_count=?,next_run=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 5 MINUTE),last_status='retry_pending' WHERE user_id=? AND revision=? AND enabled=1")->execute([$failures,$uid,$revision]);
            $finish('retry_pending',$summary);
        }
        // No request payload, secret, or raw provider error in scheduler logs.
        fwrite(STDERR,"Club automation account processing deferred\n");
    }
}
// 执行记录保留 30 天，供后台“今日”统计与排障使用。
$db->exec("DELETE FROM club_automation_runs WHERE started_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 30 DAY) LIMIT 2000");
flock($lock,LOCK_UN);
