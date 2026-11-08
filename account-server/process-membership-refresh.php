<?php
declare(strict_types=1);

/**
 * 后台会员核对worker（BE-001 修复）。
 *
 * 职责：定时刷新距上次核对已超过 300 秒的会员观测，把退款 / 取消 / 转移等
 * 外部变化写回本地权益表。这是唯一会因 RevenueCat 慢或不可达而耗时的地方，
 * 与 HTTP 请求路径完全隔离：请求只读本地 membership_entitlements。
 *
 * 仅在 CLI 运行，由 systemd timer 每分钟触发一次。
 */

if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__ . '/cli-bootstrap.php';
require_once __DIR__ . '/public/revenuecat.php';

$config = require __DIR__ . '/config.php';
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
]);

if (!revenueCatVerificationConfigured($config)) {
    fwrite(STDERR, "membership-refresh: RevenueCat 核对未配置，跳过。\n");
    exit(0);
}

$limit = max(1, min(50, (int)($argv[1] ?? 20)));
// 与 revenueCatRefreshIfDue 同口径：只有 apple 来源权益或已核对过的账号需要刷新。
$rows = $db->query(
    "SELECT u.id AS user_id, c.verified_at
       FROM users u
       LEFT JOIN revenuecat_member_checks c ON c.user_id = u.id
      WHERE u.status = 'active'
        AND (EXISTS (SELECT 1 FROM membership_entitlements m
                      WHERE m.user_id = u.id AND m.source = 'apple')
             OR c.verified_at IS NOT NULL)
        AND (c.verified_at IS NULL OR c.verified_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 300 SECOND))
      ORDER BY (c.verified_at IS NULL) DESC, c.verified_at ASC
      LIMIT " . $limit
)->fetchAll();

$refreshed = 0;
$failed = 0;
foreach ($rows as $row) {
    $userID = (int)$row['user_id'];
    try {
        revenueCatVerifyMembership($db, ['id' => $userID], $config);
        $refreshed++;
    } catch (RevenueCatVerificationError $error) {
        // 单次失败只记录，下一轮按 next_attempt_at 退避重试，不影响其他账号。
        $failed++;
    } catch (Throwable) {
        $failed++;
    }
}

echo json_encode([
    'candidates' => count($rows),
    'refreshed' => $refreshed,
    'failed' => $failed,
], JSON_UNESCAPED_UNICODE) . "\n";
