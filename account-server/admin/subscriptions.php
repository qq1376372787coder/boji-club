<?php
declare(strict_types=1);

/** Read-only operations tooling. Never calls RevenueCat/Apple or changes access. */
function subscriptionOpsAllowed(): bool {
    if (empty($GLOBALS['admin']) || !function_exists('adminRoles') || !function_exists('adminRole')) return false;
    $scopes = adminRoles()[adminRole()]['scopes'] ?? [];
    return in_array('*', $scopes, true) || in_array('users_sensitive', $scopes, true);
}

function subscriptionOpsRequireAccess(): void {
    if (!subscriptionOpsAllowed()) {
        http_response_code(403);
        throw new RuntimeException('当前角色无权查看订阅订单详情，需要成员敏感信息权限。');
    }
}

function subscriptionOpsEnvironment(array $config): array {
    $environment = strtoupper((string)($config['revenuecat_environment'] ?? 'PRODUCTION'));
    return [
        'configured' => in_array($environment, ['PRODUCTION', 'SANDBOX'], true) ? $environment : 'UNKNOWN',
        'label' => match ($environment) { 'PRODUCTION' => '正式环境', 'SANDBOX' => '沙盒测试环境', default => '环境配置无效' },
        'record_environment' => 'unknown',
        'notice' => '旧订阅、回调和核验记录未保存环境字段，环境一律未知；新回调按实际来源保留正式/沙盒环境，新核验另存请求环境范围。切换配置不会给历史记录重新归类。',
    ];
}

function subscriptionOpsActive(?array $row, int $now): bool {
    return $row !== null && ($row['status'] ?? '') === 'active' &&
        is_string($row['expires_at'] ?? null) && $row['expires_at'] > gmdate('Y-m-d H:i:s', $now);
}

function subscriptionOpsDate(?string $date): string {
    if (!$date) return '—';
    if ($date === '9999-12-31 23:59:59') return '长期有效';
    try { return (new DateTimeImmutable($date, new DateTimeZone('UTC')))->setTimezone(new DateTimeZone('Asia/Shanghai'))->format('Y-m-d H:i:s'); }
    catch (Exception) { return '日期异常'; }
}

function subscriptionOpsStatus(?array $row, int $now): string {
    if (!$row) return '无权益记录';
    if (($row['status'] ?? '') === 'revoked') return '已撤销（退款需另查）';
    return subscriptionOpsActive($row, $now) ? '有效' : '已到期 / 当前无效';
}

/** Mirrors recomputeMembership selection, without executing it or writing to DB. */
function subscriptionOpsCompare(array $subscriptions, ?array $snapshot, ?array $grant, ?array $actual, int $now): array {
    usort($subscriptions, static function (array $a, array $b) use ($now): int {
        return ((int)subscriptionOpsActive($b, $now) <=> (int)subscriptionOpsActive($a, $now)) ?:
            strcmp($b['expires_at'], $a['expires_at']) ?: ((int)$b['event_timestamp_ms'] <=> (int)$a['event_timestamp_ms']);
    });
    $best = $subscriptions ? $subscriptions[0] + ['source' => 'apple'] : null;
    $latest = 0;
    foreach ($subscriptions as $row) $latest = max($latest, (int)$row['event_timestamp_ms']);
    $basis = $best ? '订阅回调投影' : '无订单依据';
    if ($snapshot && $snapshot['observed_at_ms'] !== null && $snapshot['verified_status'] !== null && (int)$snapshot['observed_at_ms'] >= $latest) {
        $best = ['source' => 'apple', 'product_id' => $snapshot['product_id'],
            'status' => $snapshot['verified_status'] === 'active' ? 'active' : 'expired',
            'starts_at' => $snapshot['starts_at'] ?? gmdate('Y-m-d H:i:s', $now),
            'expires_at' => $snapshot['expires_at'] ?? gmdate('Y-m-d H:i:s', $now),
            'last_transaction_id' => $snapshot['purchase_id'] ?? null];
        $basis = '服务器历史核验快照';
    }
    if (subscriptionOpsActive($grant, $now) && (!$best || $best['status'] !== 'active' || $grant['expires_at'] > $best['expires_at'])) {
        $best = $grant + ['source' => 'admin', 'product_id' => 'gift', 'last_transaction_id' => null];
        $basis = '运营赠送';
    }
    $expectedActive = subscriptionOpsActive($best, $now);
    $actualActive = subscriptionOpsActive($actual, $now);
    $issues = [];
    if ($expectedActive !== $actualActive) $issues[] = $expectedActive ? '订单/赠送依据有效，但当前会员权益未生效' : '当前会员权益有效，但本地订单/赠送依据无效';
    if ($expectedActive && $actualActive) {
        if ($actual['source'] !== $best['source']) $issues[] = '会员权益来源与本地合并规则不一致';
        if ($actual['expires_at'] !== $best['expires_at']) $issues[] = '会员权益到期时间与本地依据不一致';
        if ($actual['plan_code'] !== substr($best['product_id'], 0, 60)) $issues[] = '会员方案与本地依据不一致';
        if (($actual['last_transaction_id'] ?? null) !== ($best['last_transaction_id'] ?? null)) $issues[] = '会员关联交易与本地依据不一致';
    }
    if ($actual && ($actual['status'] ?? '') === 'active' && !$actualActive) $issues[] = '权益已自然到期，数据库状态仍标为有效';
    return ['expected' => $best, 'expected_active' => $expectedActive, 'actual_active' => $actualActive,
        'basis' => $basis, 'issues' => $issues, 'consistent' => !$issues,
        'scope' => '仅核对本地数据库，不代表已向 Apple 或 RevenueCat 实时核验'];
}

/** Placeholders only for user data; LIKE wildcards in operator input are literal. */
function subscriptionOpsListQuery(array $input): array {
    $page = max(1, min(100000, (int)($input['page'] ?? 1)));
    $search = substr(trim(is_scalar($input['q'] ?? '') ? (string)($input['q'] ?? '') : ''), 0, 120);
    $status = is_string($input['status'] ?? null) ? $input['status'] : '';
    $environment = is_string($input['environment'] ?? null) && in_array($input['environment'], ['PRODUCTION','SANDBOX','unknown'], true) ? $input['environment'] : '';
    $where = ["(m.user_id IS NOT NULL OR c.user_id IS NOT NULL OR g.user_id IS NOT NULL OR EXISTS (SELECT 1 FROM revenuecat_subscriptions s0 WHERE s0.user_id=u.id) OR EXISTS (SELECT 1 FROM revenuecat_events e0 WHERE e0.user_id=u.id))"];
    $params = [];
    if ($search !== '') {
        $id = preg_match('/^(?:NO[. ]*)?([0-9]+)$/iD', $search, $match) ? (int)$match[1] : 0;
        if (preg_match('/^NO/i', $search)) $id = max(0, $id - 10000);
        $like = '%'.str_replace(['!', '%', '_'], ['!!', '!%', '!_'], $search).'%';
        $where[] = "(u.id=? OR u.phone LIKE ? ESCAPE '!' OR p.nickname LIKE ? ESCAPE '!' OR EXISTS (SELECT 1 FROM revenuecat_subscriptions sx WHERE sx.user_id=u.id AND (sx.product_id LIKE ? ESCAPE '!' OR sx.original_transaction_id LIKE ? ESCAPE '!' OR sx.last_transaction_id LIKE ? ESCAPE '!')) OR EXISTS (SELECT 1 FROM revenuecat_events ex WHERE ex.user_id=u.id AND (ex.event_id LIKE ? ESCAPE '!' OR ex.transaction_id LIKE ? ESCAPE '!' OR ex.original_transaction_id LIKE ? ESCAPE '!')))";
        $params = [$id, $like, $like, $like, $like, $like, $like, $like, $like];
    }
    if ($status === 'active') $where[] = "m.status='active' AND m.expires_at>UTC_TIMESTAMP()";
    elseif ($status === 'inactive') $where[] = "(m.user_id IS NULL OR m.status<>'active' OR m.expires_at<=UTC_TIMESTAMP())";
    elseif ($status === 'revoked') $where[] = "EXISTS (SELECT 1 FROM revenuecat_subscriptions sr WHERE sr.user_id=u.id AND sr.status='revoked')";
    elseif ($status === 'cancellation') $where[] = "EXISTS (SELECT 1 FROM revenuecat_events ec WHERE ec.user_id=u.id AND ec.event_type='CANCELLATION')";
    else $status = '';
    if ($environment === 'unknown') $where[] = "EXISTS (SELECT 1 FROM revenuecat_events ee LEFT JOIN revenuecat_event_facts ef ON ef.event_id=ee.event_id WHERE ee.user_id=u.id AND (ef.environment IS NULL OR ef.environment NOT IN ('PRODUCTION','SANDBOX')))";
    elseif ($environment !== '') { $where[] = 'EXISTS (SELECT 1 FROM revenuecat_events ee JOIN revenuecat_event_facts ef ON ef.event_id=ee.event_id WHERE ee.user_id=u.id AND ef.environment=?)'; $params[] = $environment; }
    $from = ' FROM users u LEFT JOIN profiles p ON p.user_id=u.id LEFT JOIN membership_entitlements m ON m.user_id=u.id LEFT JOIN revenuecat_member_checks c ON c.user_id=u.id LEFT JOIN membership_admin_grants g ON g.user_id=u.id WHERE '.implode(' AND ', $where);
    return ['page' => $page, 'per_page' => 25, 'search' => $search, 'status' => $status, 'environment' => $environment, 'params' => $params,
        'count_sql' => 'SELECT COUNT(*)'.$from,
        'sql' => 'SELECT u.id,u.status AS account_status,u.phone,p.nickname'.$from.' ORDER BY u.id DESC LIMIT 25 OFFSET '.(($page - 1) * 25)];
}

function subscriptionOpsQuery(PDO $db, string $sql, array $params = []): PDOStatement {
    $query = $db->prepare($sql); $query->execute($params); return $query;
}

function subscriptionOpsLoadMembers(PDO $db, array $ids, int $now): array {
    subscriptionOpsRequireAccess();
    $ids = array_values(array_unique(array_filter(array_map('intval', $ids), static fn(int $id): bool => $id > 0)));
    if (!$ids) return [];
    if (count($ids) > 25) throw new InvalidArgumentException('每次最多核对 25 位成员。');
    $marks = implode(',', array_fill(0, count($ids), '?'));
    $result = [];
    foreach ($ids as $id) $result[$id] = ['subscriptions' => [], 'snapshot' => null, 'grant' => null, 'actual' => null, 'snapshot_facts' => null];
    foreach (['subscriptions' => 'revenuecat_subscriptions', 'snapshot' => 'revenuecat_member_checks', 'grant' => 'membership_admin_grants', 'actual' => 'membership_entitlements', 'snapshot_facts' => 'revenuecat_check_facts'] as $key => $table) {
        foreach (subscriptionOpsQuery($db, 'SELECT * FROM '.$table.' WHERE user_id IN ('.$marks.')', $ids)->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $id = (int)$row['user_id'];
            if ($key === 'subscriptions') $result[$id][$key][] = $row;
            else $result[$id][$key] = $row;
        }
    }
    foreach ($result as &$member) $member['check'] = subscriptionOpsCompare($member['subscriptions'], $member['snapshot'], $member['grant'], $member['actual'], $now);
    unset($member);
    return $result;
}

/** Snapshot-consistent list and local comparison; detailed events have their own pager. */
function subscriptionOpsList(PDO $db, array $input, ?int $now = null): array {
    subscriptionOpsRequireAccess();
    $query = subscriptionOpsListQuery($input);
    $ownsTransaction = !$db->inTransaction();
    if ($ownsTransaction) $db->beginTransaction();
    try {
        $total = (int)subscriptionOpsQuery($db, $query['count_sql'], $query['params'])->fetchColumn();
        $rows = subscriptionOpsQuery($db, $query['sql'], $query['params'])->fetchAll(PDO::FETCH_ASSOC);
        $members = subscriptionOpsLoadMembers($db, array_column($rows, 'id'), $now ?? time());
        if ($ownsTransaction) $db->commit();
        return $query + ['total' => $total, 'rows' => $rows, 'members' => $members];
    } catch (Throwable $error) {
        if ($ownsTransaction && $db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

function subscriptionOpsDetail(PDO $db, int $userID, int $eventPage = 1, ?int $now = null): ?array {
    subscriptionOpsRequireAccess();
    if ($userID < 1) return null;
    $eventPage = max(1, min(100000, $eventPage));
    $ownsTransaction = !$db->inTransaction();
    if ($ownsTransaction) $db->beginTransaction();
    try {
        $user = subscriptionOpsQuery($db, 'SELECT u.id,u.status AS account_status,u.phone,p.nickname FROM users u LEFT JOIN profiles p ON p.user_id=u.id WHERE u.id=?', [$userID])->fetch(PDO::FETCH_ASSOC);
        $detail = null;
        if ($user) {
            $member = subscriptionOpsLoadMembers($db, [$userID], $now ?? time())[$userID];
            $total = (int)subscriptionOpsQuery($db, 'SELECT COUNT(*) FROM revenuecat_events WHERE user_id=?', [$userID])->fetchColumn();
            $events = subscriptionOpsQuery($db, 'SELECT e.event_id,e.event_type,e.product_id,e.transaction_id,e.original_transaction_id,e.expires_at,e.received_at,f.environment,f.cancel_reason,f.evidence_json,f.processing_result,f.source AS evidence_source FROM revenuecat_events e LEFT JOIN revenuecat_event_facts f ON f.event_id=e.event_id WHERE e.user_id=? ORDER BY e.received_at DESC,e.event_id DESC LIMIT 25 OFFSET '.(($eventPage - 1) * 25), [$userID])->fetchAll(PDO::FETCH_ASSOC);
            foreach ($events as &$event) $event['money_label'] = subscriptionOpsMoneyLabel($event['evidence_json']);
            unset($event);
            $detail = $member + ['user' => $user, 'events' => $events, 'event_total' => $total, 'event_page' => $eventPage];
        }
        if ($ownsTransaction) $db->commit();
        return $detail;
    } catch (Throwable $error) {
        if ($ownsTransaction && $db->inTransaction()) $db->rollBack();
        throw $error;
    }
}

function subscriptionOpsEventLabel(string $type): string {
    return ['INITIAL_PURCHASE' => '首次购买回调', 'RENEWAL' => '续期回调', 'CANCELLATION' => '取消事件（可能取消续订或退款）',
        'EXPIRATION' => '到期事件', 'BILLING_ISSUE' => '扣款问题', 'UNCANCELLATION' => '恢复续订',
        'REFUND_REVERSED' => '退款撤回事件', 'TRANSFER' => '账号迁移事件', 'NON_RENEWING_PURCHASE' => '非续订购买回调'][$type] ?? $type;
}

function subscriptionOpsCancelReason(?string $reason): string {
    if ($reason === null || $reason === '') return '取消原因未留存';
    return ['UNSUBSCRIBE'=>'用户取消续订（不等于退款）','BILLING_ERROR'=>'扣款错误','DEVELOPER_INITIATED'=>'开发者发起取消',
        'PRICE_INCREASE'=>'价格调整相关取消','CUSTOMER_SUPPORT'=>'客服撤销 / 退款相关（需核对官方凭据）',
        'UNKNOWN'=>'官方未明确原因'][$reason] ?? $reason;
}

function subscriptionOpsMoneyLabel(?string $json): string {
    $facts = json_decode($json ?? '{}', true);
    if (!is_array($facts)) return '金额未留存';
    $labels = [];
    foreach (['price','price_in_purchased_currency'] as $field) {
        $value = $facts[$field] ?? null;
        if (is_int($value) || is_float($value) || (is_string($value) && preg_match('/^-?[0-9]+(?:\.[0-9]+)?$/D', $value))) $labels[] = $field.'='.(string)$value;
    }
    if (!$labels) return '金额未留存';
    $currency = is_string($facts['currency'] ?? null) ? $facts['currency'] : '币种未留存';
    return implode('；', $labels).'；currency='.$currency.'（回调原始字段，非收入/退款确认）';
}

function subscriptionOpsUnlinkedEvents(PDO $db, int $page = 1): array {
    subscriptionOpsRequireAccess();
    $page=max(1,min(100000,$page));
    $total=(int)subscriptionOpsQuery($db,'SELECT COUNT(*) FROM revenuecat_events WHERE user_id IS NULL')->fetchColumn();
    $rows=subscriptionOpsQuery($db,'SELECT e.event_id,e.event_type,e.app_user_id,e.product_id,e.transaction_id,e.original_transaction_id,e.received_at,f.environment,f.cancel_reason,f.processing_result FROM revenuecat_events e LEFT JOIN revenuecat_event_facts f ON f.event_id=e.event_id WHERE e.user_id IS NULL ORDER BY e.received_at DESC,e.event_id DESC LIMIT 25 OFFSET '.(($page-1)*25))->fetchAll(PDO::FETCH_ASSOC);
    return ['total'=>$total,'rows'=>$rows,'page'=>$page];
}
