<?php
declare(strict_types=1);

/** Bounded inline attachments belong to this authenticated message, never to a Meal or public URL. */
function chatValidateImages(array $payload): array {
    $images = $payload['images'] ?? [];
    if (!is_array($images) || !array_is_list($images) || count($images) > 3) throw new RuntimeException('每条消息最多选择三张照片。', 422);
    $seen = []; $total = 0; $meta = [];
    foreach ($images as $item) {
        if (!is_array($item)) throw new RuntimeException('照片格式不正确。', 422);
        $id = (string)($item['id'] ?? '');
        if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D', $id) || isset($seen[$id])) throw new RuntimeException('照片编号不正确。', 422);
        $seen[$id] = true;
        $encoded = $item['data_base64'] ?? null;
        if (!is_string($encoded) || strlen($encoded) > 1398104 || preg_match('/[^A-Za-z0-9+\/=]/D', $encoded)) throw new RuntimeException('照片过大或格式不正确。', 422);
        $data = base64_decode($encoded, true);
        if ($data === false || strlen($data) < 50 || strlen($data) > 1048576) throw new RuntimeException('单张照片需小于 1 MB。', 422);
        $total += strlen($data);
        if ($total > 3145728 || ($item['mime_type'] ?? '') !== 'image/jpeg' || !str_starts_with($data, "\xff\xd8\xff")) throw new RuntimeException('照片大小或类型不正确。', 422);
        $hash = hash('sha256', $data);
        if (!is_string($item['sha256'] ?? null) || !hash_equals($hash, $item['sha256'])) throw new RuntimeException('照片校验失败，请重新选择。', 422);
        $size = @getimagesizefromstring($data);
        if (!$size || $size[0] > 1600 || $size[1] > 1600 || $size[0] < 1 || $size[1] < 1) throw new RuntimeException('照片尺寸不正确，请重新选择。', 422);
        $meta[] = ['id'=>$id, 'mime_type'=>'image/jpeg', 'sha256'=>$hash];
    }
    return $meta;
}

/** One millisecond only covers wire-format rounding, never meaningful session edits. */
function chatSameTimestamp127(mixed $a,mixed $b):bool {
    if($a===null||$b===null)return $a===null&&$b===null;
    if(!is_numeric($a)||!is_numeric($b))return false;
    $x=(float)$a;$y=(float)$b;
    return is_finite($x)&&is_finite($y)&&abs($x-$y)<=0.001;
}
function chatSamePauses127(array $a,array $b):bool {
    if(count($a)!==count($b))return false;
    foreach($a as $i=>$row){if(!is_array($row)||!is_array($b[$i]??null))return false;
        foreach(['start','end'] as $key)if(!chatSameTimestamp127($row[$key]??null,$b[$i][$key]??null))return false;
    }
    return true;
}

/** Compare the client's selected confirmed session with its owner's canonical business state. */
function chatWorkoutValidateState(array $state, array $request): void {
    $payload = $request['payload'] ?? [];
    if (($payload['purpose'] ?? '') !== 'workout') return;
    $date = (string)($request['date'] ?? '');
    $id = strtolower((string)($payload['source_session'] ?? ''));
    $day = $state['days'][$date] ?? null;
    if (!is_array($day)) throw new RuntimeException('请先完成本场训练记录的同步，再打开复盘。', 409);
    $session = null;
    foreach ($day['workoutSessions'] ?? [] as $item) if (strtolower((string)($item['id'] ?? '')) === $id) $session = $item;
    if (!$session || empty($session['savedAt']) || !empty($session['cancelledAt'])) throw new RuntimeException('本场训练尚未确认或已撤回，请重新核对。', 409);
    if (isset($payload['source_schedule_version']) && isset($day['_schedule_version']) && (int)$payload['source_schedule_version'] !== (int)$day['_schedule_version']) throw new RuntimeException('训练版本已变化，请重新核对。', 409);
    $claimedSession=null;
    foreach($payload['days']??[] as $row)if(($row['date']??'')===$date)foreach($row['payload']['workout_sessions']??[] as $candidate)if(strtolower((string)($candidate['id']??''))===$id)$claimedSession=$candidate;
    if(!$claimedSession)throw new RuntimeException('缺少本场训练快照。',409);
    if (!chatSamePauses127($session['pauseIntervals']??[], $claimedSession['pauseIntervals']??[])) throw new RuntimeException('本次训练暂停记录与云端不一致，请先同步并核对。',409);
    foreach(['startedAt','endedAt','savedAt'] as $field){
        $a=isset($session[$field])?(float)$session[$field]:null;$b=isset($claimedSession[$field])?(float)$claimedSession[$field]:null;
        if(!chatSameTimestamp127($a,$b))throw new RuntimeException('本场训练时间已变化，请同步并重新核对。',409);
    }
    $actual = []; $claimed = [];
    foreach ($day['exercises'] ?? [] as $exercise) {
        if (strtolower((string)($exercise['workoutSessionID'] ?? '')) !== $id) continue;
        $sets = [];
        foreach ($exercise['sets'] ?? [] as $set) {
            $duration = isset($set['durationSeconds']) ? (int)$set['durationSeconds'] : null;
            $completed = !empty($set['completed']) && ($duration !== null ? $duration > 0 : (int)($set['reps'] ?? 0) > 0);
            $sets[strtolower((string)($set['id'] ?? ''))] = [(float)($set['weight'] ?? 0),(int)($set['reps'] ?? 0),$duration,$completed];
        }
        ksort($sets); $actual[strtolower((string)$exercise['id'])] = $sets;
    }
    foreach ($payload['days'] ?? [] as $row) {
        if (($row['date'] ?? '') !== $date) continue;
        foreach ($row['payload']['exercises'] ?? [] as $exercise) {
            if (strtolower((string)($exercise['session_id'] ?? '')) !== $id) throw new RuntimeException('复盘不能混入其他训练场次。',409);
            $sets = [];
            foreach ($exercise['sets'] ?? [] as $set) $sets[strtolower((string)($set['id'] ?? ''))] = [(float)($set['weight'] ?? 0),(int)($set['reps'] ?? 0),isset($set['durationSeconds']) ? (int)$set['durationSeconds'] : null,!empty($set['completed'])];
            ksort($sets); $claimed[strtolower((string)($exercise['exercise_id'] ?? ''))] = $sets;
        }
    }
    ksort($actual); ksort($claimed);
    if (!$actual || $actual !== $claimed) throw new RuntimeException('本次训练来源与云端版本不一致，请先同步并重新核对。',409);
}
function chatValidateInput(PDO $db, int $uid, array $request): void {
    if (($request['kind'] ?? '') !== 'coach') return;
    $payload = $request['payload'] ?? [];
    chatValidateImages($payload);
    if (!empty($payload['images']) && in_array($payload['purpose'] ?? '', ['onboarding_assist','context_continue'], true)) throw new RuntimeException('请在普通 Club AI 对话中发送照片。',422);
    if (($payload['purpose'] ?? '') !== 'workout') return;
    $query = $db->prepare('SELECT state_json FROM app_states WHERE user_id=?'); $query->execute([$uid]);
    $raw = $query->fetchColumn(); $state = is_string($raw) ? json_decode($raw,true) : [];
    $state = businessStateRead($db,$uid,is_array($state)?$state:[],[(string)($request['date']??'')]);
    chatWorkoutValidateState($state,$request);
}
