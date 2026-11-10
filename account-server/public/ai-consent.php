<?php
declare(strict_types=1);

const AI_PROVIDER_NOTICE_VERSION = '2026-10-26.deepseek-minimax-v1';

/** Current reads inside a domain transaction; no stale repeatable-read snapshot. */
function aiProviderConsentAssert(PDO $db, int $uid, array $payload, bool $businessWrite = false): void {
    $requiresNotice = ($payload['_routing_version'] ?? null) === 3;
    if (!$requiresNotice && !$businessWrite) return;
    $q=$db->prepare('SELECT allowed,notice_version FROM ai_provider_consents WHERE user_id=?'.($db->inTransaction()?' FOR UPDATE':''));
    $q->execute([$uid]); $row=$q->fetch(PDO::FETCH_ASSOC);
    if ((!$row && $requiresNotice) || ($row && (!(bool)$row['allowed'] || ($requiresNotice && $row['notice_version']!==AI_PROVIDER_NOTICE_VERSION)))) {
        throw new RuntimeException('请先核对并同意新版云端分析说明。',403);
    }
}

/** Serialize withdrawal against domain writes using the same account lock. */
function aiProviderConsentSet(PDO $db, int $uid, bool $allowed): void {
    if ($db->inTransaction()) throw new LogicException('consent_requires_own_transaction');
    $db->beginTransaction();
    try {
        lockActiveUser($db,$uid);
        $db->prepare('INSERT INTO ai_provider_consents(user_id,allowed,notice_version,updated_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE allowed=VALUES(allowed),notice_version=VALUES(notice_version),updated_at=VALUES(updated_at)')
            ->execute([$uid,(int)$allowed,AI_PROVIDER_NOTICE_VERSION]);
        $db->commit();
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        throw $error;
    }
}
