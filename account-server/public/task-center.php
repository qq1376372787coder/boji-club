<?php
declare(strict_types=1);

require_once __DIR__ . '/ai-response.php';
require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/ai-runs.php';

/**
 * User-facing aggregate task center.
 *
 * It deliberately does NOT unify the underlying stores. Each task keeps its
 * own authoritative type/id; rows are folded only by a real run/client-message
 * relation or a real trace_id. Outbox details are summarised (status/count)
 * and never expose payloads, addresses or internal error stacks.
 */

function taskCenterKinds(): array {
    return ['ai_job', 'proposal', 'command', 'plan_draft', 'onboarding', 'profile_proposal'];
}

function taskCenterStatusGroup(string $type, string $status, string $businessStatus): string {
    if($status==='unknown')return 'needs_action';
    if(in_array($businessStatus,['needs_attention','sync_failed'],true))return 'needs_action';
    if($businessStatus==='syncing')return 'processing';
    if($type==='ai_job'&&$status==='succeeded'&&$businessStatus==='not_committed')return 'awaiting_confirmation';
    if (in_array($status, ['queued', 'running', 'retrying', 'processing', 'executing', 'dispatching', 'verifying_result', 'pending', 'accepted'], true)) return 'processing';
    if (in_array($status, ['awaiting_confirmation', 'draft_ready', 'review', 'deferred'], true)) return 'awaiting_confirmation';
    if (in_array($status, ['failed', 'dead_letter', 'conflict', 'rejected', 'expired'], true)) return 'needs_action';
    if (in_array($status, ['cancelled', 'compensated'], true)) return 'history';
    if (in_array($status, ['succeeded', 'completed', 'committed', 'published', 'synced', 'cleared'], true)) return 'history';
    if ($businessStatus === 'syncing') return 'processing';
    return 'history';
}

function taskCenterTitleKey(string $kind): string {
    return match ($kind) {
        'generate_plan' => 'task.initial_plan', 'parse_plan' => 'task.plan_import',
        'meal_draft' => 'task.meal_draft', 'weight_entry' => 'task.body_entry',
        'plan_activation' => 'task.plan_activation', 'plan_change_proposal' => 'task.plan_change',
        'exercise_swap' => 'task.exercise_swap', 'training_finish' => 'task.training_finish',
        'food' => 'task.meal_analysis', 'report' => 'task.daily_report', 'weekly_review' => 'task.weekly_review',
        'coach' => 'task.coach', 'onboarding' => 'task.onboarding', default => 'task.general',
    };
}

function taskCenterCursor(array $row): string {
    return rtrim(strtr(base64_encode(json_encode([$row['updated_at'], $row['task_type'], $row['task_id']], JSON_THROW_ON_ERROR)), '+/', '-_'), '=');
}

function taskCenterPosition(?string $cursor): ?array {
    if ($cursor === null || $cursor === '') return null;
    if (strlen($cursor) > 512 || !preg_match('/^[A-Za-z0-9_-]+$/D', $cursor)) throw new RuntimeException('任务分页标识不正确。', 422);
    $raw = base64_decode(strtr($cursor, '-_', '+/'), true);
    $value = $raw === false ? null : json_decode($raw, true);
    if (!is_array($value) || count($value) !== 3 || !is_string($value[0]) || !in_array($value[1], taskCenterKinds(), true) || !is_string($value[2])) {
        throw new RuntimeException('任务分页标识不正确。', 422);
    }
    return $value;
}

function taskCenterAfterCursor(array $row, ?array $position): bool {
    if ($position === null) return true;
    $cmp = strcmp((string)$row['updated_at'], (string)$position[0]);
    if ($cmp !== 0) return $cmp < 0;
    $typeCmp = strcmp((string)$row['task_type'], (string)$position[1]);
    if ($typeCmp !== 0) return $typeCmp > 0;
    return strcmp((string)$row['task_id'], (string)$position[2]) < 0;
}

function taskCenterDiscardedJobKeys(PDO $db, int $uid): array {
    $q=$db->prepare("SELECT part_key FROM cloud_parts WHERE user_id=? AND part_key LIKE 'j/%' AND JSON_EXTRACT(payload_json,'$.consumed')=true");
    $q->execute([$uid]);return array_fill_keys($q->fetchAll(PDO::FETCH_COLUMN),true);
}
function taskCenterJobRows(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT j.client_job_id,j.server_job_id,j.kind,j.completed_at,j.created_at,
        COALESCE(j.completed_at,j.created_at) AS sort_at,
        r.id AS run_id,r.status AS run_status,r.error_code,r.trace_id AS run_trace,r.conversation_id,r.updated_at AS run_updated
        FROM ai_user_jobs j
        LEFT JOIN ai_runs r ON r.user_id=j.user_id AND r.client_message_id=j.client_job_id
        WHERE j.user_id=? AND j.created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY)
        ORDER BY sort_at DESC,j.client_job_id DESC");
    $query->execute([$uid]);
    $rows = [];
    $stateQuery=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$stateQuery->execute([$uid]);$state=json_decode((string)$stateQuery->fetchColumn(),true);
    $applied=array_fill_keys(array_map('strtolower',is_array($state['appliedAIJobs']??null)?$state['appliedAIJobs']:[]),true);
    $discarded=taskCenterDiscardedJobKeys($db,$uid);
    $rawRows=$query->fetchAll(PDO::FETCH_ASSOC);
    $metadata=taskCenterPrivateMetadata($rawRows);
    foreach ($rawRows as $row) {
        $polled=$metadata[strtolower($row['server_job_id'])]??[];
        $rows[] = [
            'task_type' => 'ai_job', 'task_id' => strtolower((string)$row['client_job_id']),
            'kind' => (string)$row['kind'], 'title_key' => taskCenterTitleKey((string)$row['kind']),
            'status' => $row['run_status'] ?: ($row['completed_at'] !== null ? 'succeeded' : ($polled['status']??'unknown')),
            'business_status' => in_array($row['kind'],['generate_plan','parse_plan','food'],true) ? (isset($applied[strtolower($row['client_job_id'])])?'committed':(isset($discarded[cloudPartJobKey(strtolower($row['client_job_id']))])?'discarded':'not_committed')) : ($row['completed_at'] !== null ? 'completed' : 'pending'),
            'updated_at' => (string)($row['run_updated'] ?: $row['sort_at']),
            'source_ref' => ['type' => 'conversation', 'id' => $row['conversation_id'] ?? null, 'job_id' => strtolower((string)$row['client_job_id'])],
            'run_id' => $row['run_id'], 'trace_id' => $row['run_trace'] ?? null,
            'error_code' => ($row['error_code']??$polled['error_code']??null), 'origin' => 'server',
        ];
    }
    return $rows;
}

function taskCenterProposalRows(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT proposal_id,kind,status,expires_at,confirmed_command_id,created_at,updated_at,trace_id,conversation_id
        FROM ai_action_proposals WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY)
        ORDER BY updated_at DESC,proposal_id DESC");
    $query->execute([$uid]);
    $rows = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $status = (string)$row['status'];
        if ($status === 'awaiting_confirmation' && $row['expires_at'] !== null && strtotime((string)$row['expires_at'] . ' UTC') <= time()) $status = 'expired';
        $rows[] = ['task_type' => 'proposal', 'task_id' => strtolower((string)$row['proposal_id']),
            'kind' => (string)$row['kind'], 'title_key' => taskCenterTitleKey((string)$row['kind']),
            'status' => $status,
            'business_status' => $status === 'succeeded' ? 'committed' : ($status === 'awaiting_confirmation' ? 'not_committed' : $status),
            'updated_at' => (string)$row['updated_at'],
            'source_ref' => ['type' => 'proposal', 'id' => strtolower((string)$row['proposal_id']), 'conversation_id' => $row['conversation_id']],
            'trace_id' => $row['trace_id'], 'expires_at' => $row['expires_at'], 'origin' => 'server'];
    }
    return $rows;
}

function taskCenterCommandRows(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT operation_id,command_type,status,after_version,created_at,trace_id
        FROM data_operations WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY)
        ORDER BY created_at DESC,operation_id DESC");
    $query->execute([$uid]);
    $rows = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $rows[] = ['task_type' => 'command', 'task_id' => strtolower((string)$row['operation_id']),
            'kind' => (string)$row['command_type'], 'title_key' => taskCenterTitleKey((string)$row['command_type']),
            'status' => (string)$row['status'], 'business_status' => $row['status'] === 'succeeded' ? 'committed' : (string)$row['status'],
            'updated_at' => (string)$row['created_at'],
            'source_ref' => ['type' => 'command', 'id' => strtolower((string)$row['operation_id'])],
            'trace_id' => $row['trace_id'], 'origin' => 'server'];
    }
    return $rows;
}

function taskCenterDraftRows(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT execution_id,status,updated_at,created_at FROM ai_action_jobs
        WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY)
        ORDER BY updated_at DESC,execution_id DESC");
    $query->execute([$uid]);
    $rows = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $rows[] = ['task_type' => 'plan_draft', 'task_id' => strtolower((string)$row['execution_id']),
            'kind' => 'plan_draft', 'title_key' => 'task.plan_draft',
            'status' => (string)$row['status'], 'business_status' => $row['status'] === 'draft_ready' ? 'not_committed' : (string)$row['status'],
            'updated_at' => (string)$row['updated_at'],
            'source_ref' => ['type' => 'plan_draft', 'id' => strtolower((string)$row['execution_id'])],
            'trace_id' => null, 'origin' => 'server'];
    }
    return $rows;
}

function taskCenterOnboardingRows(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT id,status,task_kind,revision,updated_at,first_job_id,conversation_id
        FROM user_onboarding_sessions WHERE user_id=? AND status<>'completed'
        ORDER BY updated_at DESC");
    $query->execute([$uid]);
    $rows = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $rows[] = ['task_type' => 'onboarding', 'task_id' => strtolower((string)$row['id']),
            'kind' => (string)$row['task_kind'], 'title_key' => 'task.onboarding',
            'status' => (string)$row['status'], 'business_status' => 'not_committed',
            'updated_at' => (string)$row['updated_at'],
            'source_ref' => ['type' => 'onboarding', 'id' => strtolower((string)$row['id']), 'conversation_id' => $row['conversation_id'], 'job_id' => $row['first_job_id']],
            'trace_id' => null, 'origin' => 'server'];
    }
    return $rows;
}

function taskCenterSyncSummary(PDO $db, int $uid): array {
    $query = $db->prepare("SELECT trace_id,
        SUM(status IN ('pending','processing')) AS pending_count,
        SUM(status='dead_letter') AS failed_count,
        SUM(status='published') AS published_count,
        MAX(updated_at) AS updated_at
        FROM domain_outbox WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY)
        GROUP BY trace_id");
    $query->execute([$uid]);
    $out = [];
    foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
        if (!is_string($row['trace_id']) || $row['trace_id'] === '') continue;
        $out[$row['trace_id']] = ['pending' => (int)$row['pending_count'], 'failed' => (int)$row['failed_count'],
            'published' => (int)$row['published_count'], 'updated_at' => $row['updated_at']];
    }
    return $out;
}

function taskCenterAvailableActions(string $type, string $status, string $kind, array $source): array {
    if ($type === 'ai_job') {
        if (in_array($status, ['queued', 'running', 'retrying'], true)) return ['open_source', 'cancel'];
        if (in_array($status, ['failed', 'retrying'], true)) return ['open_source', 'retry'];
        if ($kind === 'generate_plan' || $kind === 'parse_plan') return ['open_source', 'open_preview'];
        return ['open_source'];
    }
    if ($type === 'profile_proposal') return ['open_preview'];
    if ($type === 'proposal') {
        if (in_array($status, ['awaiting_confirmation', 'draft_ready'], true)) return ['open_preview', 'cancel'];
        return ['open_source'];
    }
    if ($type === 'onboarding') return ['resume_onboarding'];
    if ($type === 'plan_draft') return $status === 'draft_ready' ? ['open_preview'] : ['open_source'];
    return ['open_source'];
}

function taskCenterPage(PDO $db, int $uid, array $query): array {
    $limit = filter_var($query['limit'] ?? 20, FILTER_VALIDATE_INT);
    if ($limit === false || $limit === null || $limit < 1 || $limit > 50) $limit = 20;
    $cursor = isset($query['cursor']) && is_string($query['cursor']) ? $query['cursor'] : null;
    $position = taskCenterPosition($cursor);
    $rows = array_merge(
        taskCenterJobRows($db, $uid), taskCenterProposalRows($db, $uid),
        taskCenterProfileProposalRows($db,$uid), taskCenterCommandRows($db, $uid), taskCenterDraftRows($db, $uid), taskCenterOnboardingRows($db, $uid)
    );
    // Fold real relations only: the same run/client-message, or the same trace.
    $byTrace = [];
    foreach ($rows as $index => $row) {
        $trace = $row['trace_id'] ?? null;
        if (is_string($trace) && $trace !== '') $byTrace[$trace][] = $index;
    }
    $foldedInto = [];
    foreach ($byTrace as $trace => $indexes) {
        if (count($indexes) < 2) continue;
        // The AI job is the user-facing root for that trace; others become steps.
        usort($indexes, fn($a, $b) => ($rows[$b]['task_type'] === 'ai_job') <=> ($rows[$a]['task_type'] === 'ai_job'));
        $root = $indexes[0];
        foreach (array_slice($indexes, 1) as $child) {
            if ($rows[$child]['task_type'] === 'ai_job') continue;
            $foldedInto[$child] = $root;
            $rows[$root]['steps'][] = ['task_type' => $rows[$child]['task_type'], 'task_id' => $rows[$child]['task_id'],
                'kind' => $rows[$child]['kind'], 'status' => $rows[$child]['status'],
                'business_status' => $rows[$child]['business_status']];
            if (in_array($rows[$child]['status'], ['failed', 'conflict', 'expired'], true)) $rows[$root]['business_status'] = 'needs_attention';
            if ($rows[$child]['business_status'] === 'committed' && $rows[$root]['business_status'] !== 'needs_attention') $rows[$root]['business_status'] = 'committed';
            $rows[$root]['updated_at']=max($rows[$root]['updated_at'],$rows[$child]['updated_at']);
        }
    }
    $sync = taskCenterSyncSummary($db, $uid);
    $items = [];
    foreach ($rows as $index => $row) {
        if (isset($foldedInto[$index])) continue;
        $trace = $row['trace_id'] ?? null;
        if (is_string($trace) && isset($sync[$trace])) {
            $s = $sync[$trace];
            $row['sync'] = ['pending' => $s['pending'], 'failed' => $s['failed'], 'published' => $s['published']];
            if ($s['failed'] > 0) $row['business_status'] = 'sync_failed';
            elseif ($s['pending'] > 0 && $row['business_status'] === 'committed') $row['business_status'] = 'syncing';
        }
        $row['task_key'] = $row['task_type'] . '/' . $row['task_id'];
        $row['group'] = taskCenterStatusGroup($row['task_type'], $row['status'], $row['business_status']);
        $row['available_actions'] = taskCenterAvailableActions($row['task_type'], $row['status'], $row['kind'], $row['source_ref']);
        if ($row['task_type'] === 'ai_job' && empty($row['run_id'])) {
            $row['available_actions'] = array_values(array_diff($row['available_actions'], ['cancel']));
        }
        unset($row['trace_id']);
        $items[] = $row;
    }
    usort($items, function ($a, $b) {
        $cmp = strcmp((string)$b['updated_at'], (string)$a['updated_at']);
        if ($cmp !== 0) return $cmp;
        $cmp = strcmp((string)$a['task_type'], (string)$b['task_type']);
        return $cmp !== 0 ? $cmp : strcmp((string)$a['task_id'], (string)$b['task_id']);
    });
    $group=$query['group']??null;
    $filtered = array_values(array_filter($items, fn($row) => taskCenterAfterCursor($row, $position)&&($group==='attention'?in_array($row['group'],['awaiting_confirmation','needs_action'],true):(!in_array($group,['processing','awaiting_confirmation','needs_action','history'],true)||$row['group']===$group)))); 
    $page = array_slice($filtered, 0, $limit);
    $next = count($filtered) > $limit && $page ? taskCenterCursor(end($page)) : null;
    if (!empty($query['group']) && is_string($query['group']) && in_array($query['group'], ['processing', 'awaiting_confirmation', 'needs_action', 'history'], true)) {
        $page = array_values(array_filter($page, fn($row) => $row['group'] === $query['group']));
    }
    return ['items' => $page, 'next_cursor' => $next, 'server_time' => gmdate('c')];
}

function taskCenterDetail(PDO $db, int $uid, string $type, string $id): array {
    if (!in_array($type, taskCenterKinds(), true) || !preg_match('/^[0-9a-f-]{36}$/D', strtolower($id))) throw new RuntimeException('任务编号不正确。', 422);
    $id = strtolower($id);
    if($type==='profile_proposal'){$p=profileProposalPublic($db,$uid,$id);return ['task'=>['task_key'=>'profile_proposal/'.$id,'type'=>$type,'id'=>$id,'kind'=>'profile_change','status'=>$p['status'],'business_status'=>$p['status']==='committed'?'committed':'not_committed','available_actions'=>['open_preview']],'profile_proposal'=>$p,'steps'=>[]];}
    if ($type === 'ai_job') {
        $query = $db->prepare('SELECT client_job_id,server_job_id,kind,completed_at,created_at FROM ai_user_jobs WHERE user_id=? AND client_job_id=?');
        $query->execute([$uid, $id]);
        $job = $query->fetch(PDO::FETCH_ASSOC);
        if (!$job) throw new RuntimeException('任务不存在。', 404);
        $run = $db->prepare('SELECT id,status,error_code,last_seq,updated_at FROM ai_runs WHERE user_id=? AND client_message_id=?');
        $run->execute([$uid, $id]);
        $runRow = $run->fetch(PDO::FETCH_ASSOC) ?: null;
        $meta=taskCenterPrivateMetadata([$job+['run_status'=>$runRow['status']??null]]);
        $stateQ=$db->prepare('SELECT state_json FROM app_states WHERE user_id=?');$stateQ->execute([$uid]);$state=json_decode((string)$stateQ->fetchColumn(),true);
        $applied=array_map('strtolower',is_array($state['appliedAIJobs']??null)?$state['appliedAIJobs']:[]);
        $discarded=taskCenterDiscardedJobKeys($db,$uid);
        $jobBusiness=in_array($job['kind'],['generate_plan','parse_plan','food'],true)?(in_array($id,$applied,true)?'committed':(isset($discarded[cloudPartJobKey($id)])?'discarded':'not_committed')):($job['completed_at']!==null?'completed':'pending');
        $jobStatus=$runRow['status']??($job['completed_at']!==null?'succeeded':($meta[strtolower($job['server_job_id'])]['status']??'unknown'));
        return ['task' => ['task_key' => 'ai_job/' . $id, 'type' => 'ai_job', 'id' => $id,
            'kind' => $job['kind'], 'title_key' => taskCenterTitleKey((string)$job['kind']),
            'status' => $jobStatus,
            'business_status' => $jobBusiness,
            'created_at' => $job['created_at'], 'updated_at' => $runRow['updated_at'] ?? $job['completed_at'] ?? $job['created_at'],
            'available_actions' => taskCenterAvailableActions('ai_job', $jobStatus, (string)$job['kind'], [])],
            'run' => $runRow ? ['run_id' => $runRow['id'], 'status' => $runRow['status'], 'last_event_seq' => (int)$runRow['last_seq'], 'error_code' => $runRow['error_code']] : null,
            'steps' => []];
    }
    if ($type === 'proposal') {
        $query = $db->prepare('SELECT proposal_id,kind,status,expires_at,confirmed_command_id,created_at,updated_at FROM ai_action_proposals WHERE user_id=? AND proposal_id=?');
        $query->execute([$uid, $id]);
        $row = $query->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new RuntimeException('任务不存在。', 404);
        $status = (string)$row['status'];
        if ($status === 'awaiting_confirmation' && $row['expires_at'] !== null && strtotime((string)$row['expires_at'] . ' UTC') <= time()) $status = 'expired';
        return ['task' => ['task_key' => 'proposal/' . $id, 'type' => 'proposal', 'id' => $id,
            'kind' => $row['kind'], 'title_key' => taskCenterTitleKey((string)$row['kind']), 'status' => $status,
            'business_status' => $status === 'succeeded' ? 'committed' : 'not_committed',
            'created_at' => $row['created_at'], 'updated_at' => $row['updated_at'],
            'available_actions' => taskCenterAvailableActions('proposal', $status, (string)$row['kind'], [])],
            'proposal' => ['proposal_id' => $id, 'kind' => $row['kind'], 'expires_at' => $row['expires_at'],
                'confirmed_command_id' => $row['confirmed_command_id']], 'steps' => []];
    }
    if ($type === 'command') {
        $query = $db->prepare('SELECT operation_id,command_type,status,after_version,created_at FROM data_operations WHERE user_id=? AND operation_id=?');
        $query->execute([$uid, $id]);
        $row = $query->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new RuntimeException('任务不存在。', 404);
        return ['task' => ['task_key' => 'command/' . $id, 'type' => 'command', 'id' => $id,
            'kind' => $row['command_type'], 'title_key' => taskCenterTitleKey((string)$row['command_type']),
            'status' => $row['status'], 'business_status' => $row['status'] === 'succeeded' ? 'committed' : $row['status'],
            'created_at' => $row['created_at'], 'updated_at' => $row['created_at'],
            'available_actions' => ['open_source']], 'command' => ['version' => $row['after_version']], 'steps' => []];
    }
    if ($type === 'plan_draft') {
        $query = $db->prepare('SELECT execution_id,status,updated_at,created_at FROM ai_action_jobs WHERE user_id=? AND execution_id=?');
        $query->execute([$uid, $id]);
        $row = $query->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new RuntimeException('任务不存在。', 404);
        return ['task' => ['task_key' => 'plan_draft/' . $id, 'type' => 'plan_draft', 'id' => $id,
            'kind' => 'plan_draft', 'title_key' => 'task.plan_draft', 'status' => $row['status'],
            'business_status' => 'not_committed', 'created_at' => $row['created_at'], 'updated_at' => $row['updated_at'],
            'available_actions' => taskCenterAvailableActions('plan_draft', (string)$row['status'], 'plan_draft', [])], 'steps' => []];
    }
    $query = $db->prepare('SELECT id,status,task_kind,revision,updated_at FROM user_onboarding_sessions WHERE user_id=? AND id=?');
    $query->execute([$uid, $id]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    if (!$row) throw new RuntimeException('任务不存在。', 404);
    return ['task' => ['task_key' => 'onboarding/' . $id, 'type' => 'onboarding', 'id' => $id,
        'kind' => $row['task_kind'], 'title_key' => 'task.onboarding', 'status' => $row['status'],
        'business_status' => 'not_committed', 'created_at' => null, 'updated_at' => $row['updated_at'],
        'available_actions' => taskCenterAvailableActions('onboarding', (string)$row['status'], (string)$row['task_kind'], [])],
        'onboarding' => ['revision' => (int)$row['revision']], 'steps' => []];
}

/** Only metadata for this account's own opaque server IDs; no model requests. */
function taskCenterPrivateMetadata(array $rows):array {
 $config=$GLOBALS['config']??[];
 if(empty($config['ai_proxy_token'])&&!isset($GLOBALS['boji_action_transport']))return [];
 $ids=[];foreach($rows as $r)if(empty($r['run_status'])&&empty($r['completed_at']))$ids[]=strtolower($r['server_job_id']);
 $result=[];$deadline=microtime(true)+2;
 foreach(array_chunk(array_slice(array_unique($ids),0,500),50) as $chunk){
  if(microtime(true)>$deadline)break;
  try{$reply=actionPrivateRequest($config,'POST','/v1/jobs/metadata',['ids'=>$chunk],max(.5,$deadline-microtime(true)));}
  catch(Throwable){break;}
  foreach($reply['items']??[] as $item)if(in_array($item['id']??'', $chunk,true)&&in_array($item['status']??'', ['queued','running','retrying','failed','succeeded','expired','deleted','cancelled'],true))$result[$item['id']]=$item;
 }
 return $result;
}

function taskCenterProfileProposalRows(PDO $db,int $uid):array {
 $q=$db->prepare("SELECT proposal_id,status,expires_at,created_at,updated_at FROM user_onboarding_proposals WHERE user_id=? AND session_id IS NULL AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 90 DAY) ORDER BY updated_at DESC,proposal_id DESC");$q->execute([$uid]);$rows=[];
 foreach($q->fetchAll(PDO::FETCH_ASSOC) as $p){$status=$p['status'];if($status==='awaiting_confirmation'&&strtotime($p['expires_at'].' UTC')<=time())$status='expired';
 $rows[]=['task_type'=>'profile_proposal','task_id'=>$p['proposal_id'],'kind'=>'profile_change','title_key'=>'task.profile_change','status'=>$status,'business_status'=>$status==='committed'?'committed':'not_committed','updated_at'=>$p['updated_at'],'source_ref'=>['type'=>'profile_proposal','id'=>$p['proposal_id']],'trace_id'=>null,'origin'=>'server'];}
 return $rows;
}
