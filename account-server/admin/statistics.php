<?php
declare(strict_types=1);

/** Project only seven days of counts; never download whole member histories. */
function overviewActivity(PDO $db, array $dates): array {
    $columns = []; $params = [];
    foreach ($dates as $index => $date) {
        if (!is_string($date) || !preg_match('/^\d{4}-\d{2}-\d{2}$/D', $date)) throw new InvalidArgumentException('Invalid date');
        $columns[] = "JSON_LENGTH(JSON_EXTRACT(state_json,?)) AS meals_$index";
        $columns[] = "JSON_EXTRACT(state_json,?) AS sets_$index";
        $params[] = '$.days."'.$date.'".meals';
        $params[] = '$.days."'.$date.'".exercises[*].sets[*].completed';
    }
    $ownsTransaction = !$db->inTransaction();
    if ($ownsTransaction) $db->beginTransaction();
    try {
        $activeUsers = [];
        $activity = array_fill_keys($dates, 0); $active = 0; $meals = 0; $sets = 0; $daily=[];
        if (!$columns) {
            if ($ownsTransaction && $db->inTransaction()) $db->commit();
            return compact('activity','active','meals','sets');
        }
        $q = $db->prepare('SELECT user_id,'.implode(',', $columns).' FROM app_states'); $q->execute($params);
        while ($row = $q->fetch(PDO::FETCH_ASSOC)) {
            foreach ($dates as $index => $date) {
                $values = json_decode((string)($row['sets_'.$index] ?? '[]'), true);
                $completed = is_array($values) ? count(array_filter($values, static fn($value) => $value === true)) : 0;
                $daily[(int)$row['user_id']][$date]=['meals'=>(int)($row['meals_'.$index]??0),'sets'=>$completed];
            }
        }
        $marks = implode(',', array_fill(0, count($dates), '?'));
        $q = $db->prepare("SELECT user_id,date_key,JSON_LENGTH(JSON_EXTRACT(payload_json,'$.meals')) AS meals,JSON_EXTRACT(payload_json,'$.exercises[*].sets[*].completed') AS sets FROM cloud_parts WHERE part_key LIKE 'd/%' AND date_key IN (".$marks.")");
        $q->execute($dates);
        while ($row = $q->fetch(PDO::FETCH_ASSOC)) {
            $values = json_decode((string)($row['sets'] ?? '[]'), true);
            $completed = is_array($values) ? count(array_filter($values, static fn($v) => $v === true)) : 0;
            // A per-day part is authoritative, including an empty day after deletion.
            $daily[(int)$row['user_id']][$row['date_key']]=['meals'=>(int)$row['meals'],'sets'=>$completed];
        }
        foreach($daily as $userId=>$days)foreach($days as $date=>$counts){
            $meals+=$counts['meals'];$sets+=$counts['sets'];
            if($counts['sets']>0){$activity[$date]++;$activeUsers[$userId]=true;}
        }
        $active = count($activeUsers);
        if ($ownsTransaction && $db->inTransaction()) $db->commit();
        return compact('activity','active','meals','sets');
    } catch (Throwable $e) {
        if ($ownsTransaction && $db->inTransaction()) $db->rollBack();
        throw $e;
    }
}
