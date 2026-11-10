<?php
declare(strict_types=1);

/**
 * Transactional Outbox Background Worker (A3 Architecture) — Phase 4.
 *
 * Consumes events from domain_outbox in an idempotent, leased manner and
 * dispatches them to every interested consumer. Each consumer records a
 * receipt in domain_consumer_inbox, so a repeated delivery is a no-op and the
 * projections converge even after a crash or a requeue (spec §8).
 *
 * Consumers:
 *   personal-memory-v1  long-term memory extraction from confirmed records
 *   notifications-v1    notification_deliveries rows (push/notification queue)
 *   club-progress-v1    club projection freshness marker
 *   home-insight-v1     home insight projection freshness marker
 *
 * The authoritative training calendar is never rebuilt from events: it is read
 * from the Schedule/Plan domain state (spec §8). Events only feed derived
 * projections, and a lagging projection is visible, never silently wrong.
 */

require_once __DIR__ . '/cli-bootstrap.php';
$config = require __DIR__ . '/config.php';
$GLOBALS['config'] = $config;

/** Portable UUIDv4: the CLI SAPI may lack the uuid extension (FPM has it). */
function outboxUUID(): string {
    if (function_exists('uuid_create')) return (string)uuid_create();
    $bytes = random_bytes(16);
    $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
    $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
    $hex = bin2hex($bytes);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20,12);
}
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
]);

require_once __DIR__ . '/public/cloud-parts.php';
require_once __DIR__ . '/public/insights.php';
require_once __DIR__ . '/public/ai-memory.php';
require_once __DIR__ . '/public/domain-consumers.php';

// Recover crashed workers; a crash consumes an attempt just like an exception.
$db->exec("UPDATE domain_outbox SET status=IF(attempts>=5,'dead_letter','pending'),lease_token=NULL,next_attempt=UTC_TIMESTAMP(),updated_at=UTC_TIMESTAMP() WHERE status='processing' AND updated_at<DATE_SUB(UTC_TIMESTAMP(), INTERVAL 5 MINUTE)");
$leaseToken = outboxUUID();

// 1. Claim pending events with lease
$db->beginTransaction();
$q = $db->prepare("SELECT event_id, operation_id, user_id, aggregate_type, aggregate_id, aggregate_version, event_type, payload, attempts FROM domain_outbox WHERE status='pending' AND next_attempt<=UTC_TIMESTAMP() ORDER BY created_at ASC LIMIT 50 FOR UPDATE");
$q->execute();
$events = $q->fetchAll();

if (!empty($events)) {
    $ids = array_column($events, 'event_id');
    $placeholders = implode(',', array_fill(0, count($ids), '?'));
    $updateStmt = $db->prepare("UPDATE domain_outbox SET status='processing', attempts=attempts+1, lease_token=?, updated_at=UTC_TIMESTAMP() WHERE event_id IN ($placeholders)");
    $updateStmt->execute(array_merge([$leaseToken], $ids));
}
$db->commit();

/** Record that a consumer processed an event (idempotency + freshness). */
function outboxRecordProjectionLegacy(PDO $db, int $userId, string $consumer, string $eventId, string $eventType): void {
    outboxRecordProjection($db, $userId, $consumer, $eventId);
}

// 2. Process claimed events
foreach ($events as $event) {
    $eventId = $event['event_id'];
    $attempts = (int)$event['attempts'] + 1;
    $success = false;
    $errorReason = null;
    try {
        outboxDispatch($db, $event);
        $success = true;
    } catch (Throwable $e) {
        if ($db->inTransaction()) $db->rollBack();
        $success = false;
        $errorReason = substr($e->getMessage(), 0, 190);
    }

    if ($success) {
        $db->prepare("UPDATE domain_outbox SET status='published', lease_token=NULL, updated_at=UTC_TIMESTAMP() WHERE event_id=? AND lease_token=?")
            ->execute([$eventId, $leaseToken]);
    } else {
        if ($attempts >= 5) {
            // Move to dead-letter queue
            $db->prepare("UPDATE domain_outbox SET status='dead_letter', attempts=?, lease_token=NULL, updated_at=UTC_TIMESTAMP() WHERE event_id=? AND lease_token=?")
                ->execute([$attempts, $eventId, $leaseToken]);
        } else {
            // Exponential backoff: 30s, 60s, 120s, 240s
            $delay = 30 * (2 ** ($attempts - 1));
            $db->prepare("UPDATE domain_outbox SET status='pending', attempts=?, next_attempt=DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? SECOND), lease_token=NULL, updated_at=UTC_TIMESTAMP() WHERE event_id=? AND lease_token=?")
                ->execute([$attempts, $delay, $eventId, $leaseToken]);
        }
    }
}

// 3. Cleanup old published events older than 14 days
$db->exec("DELETE FROM domain_outbox WHERE status='published' AND updated_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 14 DAY) LIMIT 1000");

echo "PROCESSED_EVENTS count=" . count($events) . "\n";
