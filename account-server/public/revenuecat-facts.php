<?php
declare(strict_types=1);

/** Exact scalar fields supplied by the authenticated webhook, without inferred money. */
function revenueCatEventEvidence(array $event): array {
    $facts = [];
    foreach (['id','type','app_id','store','environment','event_timestamp_ms','purchased_at_ms','expiration_at_ms',
        'transaction_id','original_transaction_id','cancel_reason','expiration_reason','price','currency',
        'price_in_purchased_currency','tax_percentage','commission_percentage','takehome_percentage'] as $key) {
        if (array_key_exists($key, $event) && (is_scalar($event[$key]) || $event[$key] === null)) $facts[$key] = $event[$key];
    }
    return $facts;
}

/** Called inside the existing webhook transaction after its audit row is inserted. */
function revenueCatRecordEventFacts(PDO $db, array $event, string $result): void {
    $text = static fn(string $key, int $limit): ?string => is_string($event[$key] ?? null) ? substr($event[$key], 0, $limit) : null;
    $db->prepare('INSERT INTO revenuecat_event_facts(event_id,environment,store_name,cancel_reason,evidence_json,processing_result,recorded_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())')->execute([
        $event['id'], $text('environment',32), $text('store',60), $text('cancel_reason',100),
        json_encode(revenueCatEventEvidence($event), JSON_THROW_ON_ERROR | JSON_PRESERVE_ZERO_FRACTION), $result,
    ]);
}

function revenueCatUpdateEventFactResult(PDO $db, string $eventID, string $result): void {
    $db->prepare('UPDATE revenuecat_event_facts SET processing_result=? WHERE event_id=?')->execute([$result,$eventID]);
}

/** Preserve ignored TRANSFER evidence too; the access policy still returns ignored. */
function revenueCatRecordIgnoredTransferFacts(PDO $db, array $event): void {
    $db->beginTransaction();
    try {
        $query=$db->prepare('SELECT 1 FROM revenuecat_events WHERE event_id=?');$query->execute([$event['id']]);
        if (!$query->fetchColumn()) {
            $db->prepare("INSERT INTO revenuecat_events(event_id,event_type,app_user_id,product_id,payload_hash,received_at) VALUES(?,'TRANSFER','','',?,UTC_TIMESTAMP())")->execute([$event['id'],hash('sha256',json_encode($event,JSON_THROW_ON_ERROR))]);
            revenueCatRecordEventFacts($db,$event,'ignored');
        }
        $db->commit();
    } catch(Throwable $error) { if($db->inTransaction())$db->rollBack();throw $error; }
}

/** The environment is the server API request scope, never a backfill for old orders. */
function revenueCatRecordCheckFacts(PDO $db, array $config, int $userID, int $observedMS, array $snapshot, bool $serverFetch): void {
    $environment = $config['revenuecat_environment'] ?? 'PRODUCTION';
    $environment = is_string($environment) && in_array(strtoupper($environment), ['PRODUCTION','SANDBOX'], true) ? strtoupper($environment) : null;
    $project = is_string($config['revenuecat_project_id'] ?? null) ? substr($config['revenuecat_project_id'],0,64) : null;
    $db->prepare('INSERT INTO revenuecat_check_facts(user_id,observed_at_ms,source,environment_scope,project_id,verified_status,recorded_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE observed_at_ms=VALUES(observed_at_ms),source=VALUES(source),environment_scope=VALUES(environment_scope),project_id=VALUES(project_id),verified_status=VALUES(verified_status),recorded_at=VALUES(recorded_at)')->execute([
        $userID,$observedMS,$serverFetch?'revenuecat_api_v2':'injected_provider',$environment,$project,$snapshot['active']?'active':'inactive',
    ]);
}
