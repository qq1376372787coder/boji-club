<?php
declare(strict_types=1);
// Dry run by default. Only repair values attributable to the old BodyWeight.Create command.
if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__ . '/public/commands.php';
function fail(string $message, int $status = 400): never { throw new RuntimeException($message, $status); }
function respond(int $status, array $payload): never { throw new RuntimeException($payload['error'] ?? 'response', $status); }
$config = require __DIR__ . '/config.php';
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$apply = in_array('--apply', $argv, true); $found = 0; $fixed = 0;
$rows = $db->query("SELECT user_id,aggregate_id,MAX(created_at) AS created_at FROM data_operations WHERE command_type='BodyWeight.Create' AND status='succeeded' GROUP BY user_id,aggregate_id")->fetchAll();
foreach ($rows as $row) {
    $uid=(int)$row['user_id']; $date=$row['aggregate_id'];
    $db->beginTransaction();
    try {
        $q=$db->prepare('SELECT id FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);
        $q=$db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE');$q->execute([$uid]);$stored=$q->fetch();
        if (!$stored) {$db->rollBack();continue;}
        $raw=json_decode($stored['state_json'],true);$partitioned=($raw['_partitioned']??null)===2;
        $state=businessStateRead($db,$uid,$raw,[$date]);$before=$state;
        $stamp=$state['days'][$date]['bodyWeight']['updatedAt']??null;
        $eventTime=(new DateTimeImmutable($row['created_at'],new DateTimeZone('UTC')))->getTimestamp();
        // Require both a future-in-Swift value and correlation with the exact legacy command time.
        if (!is_numeric($stamp) || $stamp <= businessDocumentNow()+86400 || abs($stamp-$eventTime)>120) {$db->rollBack();continue;}
        $found++;
        if (!$apply) {$db->rollBack();continue;}
        $state['days'][$date]['bodyWeight']['updatedAt']=$stamp-978307200;
        businessStateWrite($db,$uid,$state,$before,$partitioned,(int)$stored['revision']+1);
        $id=commandUUID();
        $detail=json_encode(['updatedAt_before'=>$stamp,'updatedAt_after'=>$stamp-978307200]);
        $db->prepare("INSERT INTO data_operations(operation_id,user_id,actor,command_type,payload_hash,aggregate_type,aggregate_id,before_version,after_version,diff_json,status,created_at) VALUES(?,?,'system','BodyWeight.TimestampRepair',?,'body',?,?,?,?,'succeeded',UTC_TIMESTAMP())")
            ->execute([$id,$uid,hash('sha256',$detail),$date,(string)$stored['revision'],(string)((int)$stored['revision']+1),$detail]);
        $db->commit();$fixed++;
    } catch(Throwable $error) {if($db->inTransaction())$db->rollBack();throw $error;}
}
echo json_encode(['mode'=>$apply?'apply':'dry_run','candidates'=>$found,'repaired'=>$fixed],JSON_UNESCAPED_UNICODE)."\n";
