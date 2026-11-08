<?php
declare(strict_types=1);

require_once __DIR__ . '/membership-access.php';

/** RevenueCat webhook and server-side membership checks. */
function revenueCatWebhookAuthorized(array $config): bool {
    $expected = (string)($config['revenuecat_webhook_authorization'] ?? '');
    $actual = (string)($_SERVER['HTTP_AUTHORIZATION'] ?? '');
    return strlen($expected) >= 24 && $actual !== '' && hash_equals($expected, $actual);
}
function revenueCatMemberUserID(mixed $value): ?int {
    if (!is_string($value) || !preg_match('/^boji-([1-9][0-9]{0,18})$/D', $value, $match)) return null;
    $id = (int)$match[1]; return $id > 0 ? $id : null;
}
function revenueCatDate(mixed $milliseconds): ?string {
    if (!is_int($milliseconds) && !is_float($milliseconds) && !is_string($milliseconds)) return null;
    if (!is_numeric($milliseconds)) return null;
    $seconds = (int)floor(((float)$milliseconds) / 1000);
    if ($seconds < 946684800 || $seconds > 4102444800) return null;
    return gmdate('Y-m-d H:i:s', $seconds);
}
// Retained as an internal compatibility name; the old global free-access switch is retired.
function membershipEnforced(array $config): bool { return true; }
function requireActiveMembership(PDO $db, array $user, array $config): void {
    revenueCatRefreshIfDue($db, $user, $config);
    if (!membershipHasActiveEntitlement($db, (int)$user['id'])) fail('请先加入薄肌俱乐部后使用此功能。', 403, 'membership_required');
}
/**
 * 当前唯一在售商品档位（2026-10 起）：月 ¥12 / 年 ¥28 / 永久 ¥38。
 * 这是发放权益的唯一白名单；配置缺失时也只认这一套。
 */
function revenueCatProductIDs(array $config): array {
    $products = $config['revenuecat_product_ids'] ?? ['yuefu', 'nianfu', 'yongjiu'];
    if (is_string($products)) $products = [$products];
    return is_array($products) ? array_values(array_filter($products, 'is_string')) : [];
}

/**
 * 已下架的旧档商品（两档 ¥29.9/¥42.9 及更早的 monthly/six_month/lifetime）。
 *
 * 只服务于「已经买过这些商品的老订阅」的续订、过期与退款，绝不发放新权益：
 * revenueCatDecision() 仅在该 original_transaction_id 已存在于
 * revenuecat_subscriptions 时才接受这些商品的事件。清理旧 ID 指的是把它们
 * 移出发放白名单，而不是让老付费用户的权益凭空失效。
 */
function revenueCatLegacyProductIDs(array $config): array {
    $legacy = $config['revenuecat_legacy_product_ids'] ?? ['monthly', 'six_month', 'lifetime', 'bojiclub_halfyear_2990', 'bojiclub_yearly_4290'];
    if (is_string($legacy)) $legacy = [$legacy];
    return is_array($legacy) ? array_values(array_filter($legacy, 'is_string')) : [];
}

function revenueCatSupportedProduct(array $config, string $productID): bool {
    return in_array($productID, revenueCatProductIDs($config), true)
        || in_array($productID, revenueCatLegacyProductIDs($config), true);
}
require_once __DIR__ . '/revenuecat-policy.php';
require_once __DIR__ . '/revenuecat-verify.php';
require_once __DIR__ . '/revenuecat-facts.php';

function processRevenueCatEvent(PDO $db, array $config, array $event): array {
    $eventID = $event['id'] ?? null;
    if (!is_string($eventID) || !preg_match('/^[A-Za-z0-9._:-]{8,191}$/D', $eventID)) throw new InvalidArgumentException('Invalid event ID');
    if (($event['type'] ?? '') === 'TRANSFER') return processRevenueCatTransfer($db, $config, $event);
    $appUserID = (string)($event['app_user_id'] ?? '');
    $userID = revenueCatMemberUserID($appUserID);
    // 旧档商品只允许续订/过期已存在的订阅；只有这些事件才需要一次额外查询。
    $knownOriginal = false;
    $eventProduct = (string)($event['product_id'] ?? '');
    if ($eventProduct !== '' && !in_array($eventProduct, revenueCatProductIDs($config), true)
        && in_array($eventProduct, revenueCatLegacyProductIDs($config), true)) {
        $originalID = (string)($event['original_transaction_id'] ?? '');
        if ($originalID !== '') {
            $knownRow = $db->prepare('SELECT 1 FROM revenuecat_subscriptions WHERE original_transaction_id=? LIMIT 1');
            $knownRow->execute([$originalID]);
            $knownOriginal = (bool)$knownRow->fetchColumn();
        }
    }
    $decision = revenueCatDecision($event, $config, $knownOriginal);
    $db->beginTransaction();
    try {
        // This common lock serializes all subscriptions of one account, including deletion.
        $known = false;
        if ($userID !== null) {
            $user = $db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE'); $user->execute([$userID]);
            $known = $user->fetchColumn() === 'active';
        }
        $exists = $db->prepare('SELECT 1 FROM revenuecat_events WHERE event_id=?'); $exists->execute([$eventID]);
        if ($exists->fetchColumn()) { $db->commit(); return ['received'=>true, 'duplicate'=>true]; }
        $audit = $db->prepare('INSERT INTO revenuecat_events(event_id,event_type,user_id,app_user_id,product_id,transaction_id,original_transaction_id,expires_at,payload_hash,received_at) VALUES(?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())');
        $transaction = substr((string)($event['transaction_id'] ?? ''), 0, 255);
        $audit->execute([$eventID,substr((string)($event['type'] ?? ''),0,60),$known ? $userID : null,substr($appUserID,0,191),substr((string)($event['product_id'] ?? ''),0,191),$transaction ?: null,substr((string)($event['original_transaction_id'] ?? ''),0,255) ?: null,revenueCatDate($event['expiration_at_ms'] ?? null),hash('sha256',json_encode($event,JSON_THROW_ON_ERROR))]);
        revenueCatRecordEventFacts($db,$event,'recorded');
        if (!$known || $decision === null) { revenueCatUpdateEventFactResult($db,$eventID,'ignored'); $db->commit(); return ['received'=>true,'ignored'=>true]; }
        $current = $db->prepare('SELECT user_id,event_timestamp_ms,status,expires_at FROM revenuecat_subscriptions WHERE original_transaction_id=? FOR UPDATE');
        $current->execute([$decision['original']]); $previous = $current->fetch();
        // A purchase cannot silently transfer to another account through a webhook.
        if ($previous && (int)$previous['user_id'] !== $userID) { revenueCatUpdateEventFactResult($db,$eventID,'identity_conflict'); $db->commit(); return ['received'=>true,'ignored'=>true]; }
        $rank = ['active'=>0,'expired'=>1,'revoked'=>2];
        $sameTimeLoses = $previous && (int)$previous['event_timestamp_ms'] === $decision['time']
            && $rank[$decision['status']] <= $rank[$previous['status']]
            && !($previous['status'] === 'active' && $decision['status'] === 'active' && $decision['expires'] > $previous['expires_at']);
        if ($previous && ((int)$previous['event_timestamp_ms'] > $decision['time'] || $sameTimeLoses)) { revenueCatUpdateEventFactResult($db,$eventID,'stale'); $db->commit(); return ['received'=>true,'stale'=>true]; }
        $db->prepare('INSERT INTO revenuecat_subscriptions(original_transaction_id,user_id,product_id,status,starts_at,expires_at,event_timestamp_ms,last_transaction_id) VALUES(?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE product_id=VALUES(product_id),status=VALUES(status),expires_at=VALUES(expires_at),event_timestamp_ms=VALUES(event_timestamp_ms),last_transaction_id=VALUES(last_transaction_id)')->execute([$decision['original'],$userID,$event['product_id'],$decision['status'],revenueCatDate($event['purchased_at_ms'] ?? null) ?? gmdate('Y-m-d H:i:s'),$decision['expires'],$decision['time'],$transaction ?: $decision['original']]);
        recomputeMembership($db, $userID);
        revenueCatUpdateEventFactResult($db,$eventID,'applied');
        $db->commit(); return ['received'=>true];
    } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack(); throw $error; }
}

function revenueCatWebhook(PDO $db, array $config): never {
    if (!revenueCatWebhookAuthorized($config)) fail('Webhook 未授权。',401);
    $input = body(512*1024); $event = $input['event'] ?? null;
    if (!is_array($event)) fail('Webhook 事件格式不正确。',400);
    try { $result = processRevenueCatEvent($db,$config,$event); }
    catch (InvalidArgumentException) { fail('Webhook 事件编号不正确。',400); }
    catch (Throwable) { fail('Webhook 处理失败。',503); }
    respond(200,$result);
}

/** Caller holds the users row lock. Paid purchases and operator grants stay separate. */
function recomputeMembership(PDO $db, int $userID): void {
    $q=$db->prepare("SELECT *, 'apple' AS source FROM revenuecat_subscriptions WHERE user_id=? ORDER BY (status='active' AND expires_at>UTC_TIMESTAMP()) DESC,expires_at DESC,event_timestamp_ms DESC LIMIT 1");
    $q->execute([$userID]); $best=$q->fetch();
    $q=$db->prepare('SELECT * FROM revenuecat_member_checks WHERE user_id=?'); $q->execute([$userID]); $snapshot=$q->fetch();
    $q=$db->prepare('SELECT MAX(event_timestamp_ms) FROM revenuecat_subscriptions WHERE user_id=?'); $q->execute([$userID]); $latestEvent=(int)$q->fetchColumn();
    // A complete REST observation supersedes older webhook rows, including a
    // refunded lifetime purchase. A newer concurrent webhook still wins.
    if ($snapshot && $snapshot['observed_at_ms'] !== null && $snapshot['verified_status'] !== null && (int)$snapshot['observed_at_ms'] >= $latestEvent) {
        $best=['source'=>'apple','product_id'=>$snapshot['product_id'],'status'=>$snapshot['verified_status']==='active'?'active':'expired',
            'starts_at'=>$snapshot['starts_at'] ?? gmdate('Y-m-d H:i:s'),'expires_at'=>$snapshot['expires_at'] ?? gmdate('Y-m-d H:i:s'),
            'last_transaction_id'=>$snapshot['purchase_id']];
    }
    $q=$db->prepare('SELECT * FROM membership_admin_grants WHERE user_id=?'); $q->execute([$userID]); $gift=$q->fetch();
    if ($gift && $gift['status']==='active' && strtotime($gift['expires_at'].' UTC')>time() && (!$best || $best['status']!=='active' || $gift['expires_at']>$best['expires_at'])) {
        $best=$gift + ['source'=>'admin','product_id'=>'gift','last_transaction_id'=>null];
    }
    if (!$best) {
        $db->prepare("UPDATE membership_entitlements SET status='expired',expires_at=LEAST(expires_at,UTC_TIMESTAMP()),last_transaction_id=NULL,updated_at=UTC_TIMESTAMP() WHERE user_id=?")->execute([$userID]);
        return;
    }
    $status=$best['status'];
    if ($status==='active' && strtotime($best['expires_at'].' UTC')<=time()) $status='expired';
    $db->prepare("INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,last_transaction_id,operator_note,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'权益合并',UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status=VALUES(status),source=VALUES(source),plan_code=VALUES(plan_code),starts_at=VALUES(starts_at),expires_at=VALUES(expires_at),last_transaction_id=VALUES(last_transaction_id),updated_at=UTC_TIMESTAMP()")->execute([$userID,$status,$best['source'],substr($best['product_id'],0,60),$best['starts_at'],$best['expires_at'],$best['last_transaction_id']]);
}

function processRevenueCatTransfer(PDO $db, array $config, array $event): array {
    // TRANSFER has no guaranteed environment field. This endpoint is authenticated;
    // only subscriptions already accepted by the product/environment policy move here.
    if ((isset($event['environment']) && $event['environment']!==($config['revenuecat_environment'] ?? 'PRODUCTION')) || (!empty($config['revenuecat_app_id']) && ($event['app_id'] ?? '')!==$config['revenuecat_app_id'])) { revenueCatRecordIgnoredTransferFacts($db,$event); return ['received'=>true,'ignored'=>true]; }
    if (!empty($config['revenuecat_store']) && isset($event['store']) && $event['store'] !== $config['revenuecat_store']) { revenueCatRecordIgnoredTransferFacts($db,$event); return ['received'=>true,'ignored'=>true]; }
    $time=$event['event_timestamp_ms'] ?? null;
    if (!is_numeric($time) || (int)$time<946684800000) throw new InvalidArgumentException('Invalid transfer timestamp');
    $ids=static function($values): array {
        if (!is_array($values)) throw new InvalidArgumentException('Invalid transfer users');
        return array_values(array_unique(array_filter(array_map('revenueCatMemberUserID',$values))));
    };
    $from=$ids($event['transferred_from'] ?? []); $to=$ids($event['transferred_to'] ?? []);
    // A Boji login has one stable identified account. Ambiguous transfers require reconciliation.
    if (count($to)!==1 || !$from) throw new RuntimeException('Transfer requires an identified source and destination');
    $target=$to[0]; $all=array_values(array_unique(array_merge($from,$to))); sort($all,SORT_NUMERIC);
    // Purchases made before Webhooks were enabled may exist only in REST snapshots.
    // Reconcile the new owner before taking locks rather than copying stale access.
    if (revenueCatVerificationConfigured($config)) {
        $q=$db->prepare('SELECT status FROM users WHERE id=?');$q->execute([$target]);
        if ($q->fetchColumn()==='active') revenueCatVerifyMembership($db,['id'=>$target],$config,true);
    }
    $db->beginTransaction();
    try {
        $known=[];
        foreach($all as $id) { $q=$db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE');$q->execute([$id]);$known[$id]=$q->fetchColumn()==='active'; }
        if (!$known[$target]) throw new RuntimeException('Transfer destination unavailable');
        $q=$db->prepare('SELECT 1 FROM revenuecat_events WHERE event_id=?');$q->execute([$event['id']]);
        if($q->fetchColumn()){$db->commit();return ['received'=>true,'duplicate'=>true];}
        foreach($from as $source) {
            if($source===$target) continue;
            revenueCatInvalidateSnapshot($db,$source,(int)$time);
            $q=$db->prepare('UPDATE revenuecat_subscriptions SET user_id=?,event_timestamp_ms=? WHERE user_id=? AND event_timestamp_ms<=?');
            $q->execute([$target,(int)$time,$source,(int)$time]);
            if($known[$source]) recomputeMembership($db,$source);
        }
        $q=$db->prepare('SELECT COUNT(*) FROM revenuecat_subscriptions WHERE user_id=?');$q->execute([$target]);
        // Account deletion cascades subscription rows. Never acknowledge an empty
        // restore as completed; RevenueCat must retry while support reconciles it.
        if(!(int)$q->fetchColumn()) {
            $verified=$db->prepare('SELECT observed_at_ms,verified_status FROM revenuecat_member_checks WHERE user_id=?');$verified->execute([$target]);$snapshot=$verified->fetch();
            if (!$snapshot || $snapshot['verified_status']===null || (int)$snapshot['observed_at_ms']<=(int)$time) throw new RuntimeException('Transfer requires authoritative subscription reconciliation');
        }
        revenueCatInvalidateSnapshot($db,$target,(int)$time);
        recomputeMembership($db,$target);
        $db->prepare("INSERT INTO revenuecat_events(event_id,event_type,user_id,app_user_id,product_id,payload_hash,received_at) VALUES(?,'TRANSFER',?,?,'',?,UTC_TIMESTAMP())")->execute([$event['id'],$target,'boji-'.$target,hash('sha256',json_encode($event,JSON_THROW_ON_ERROR))]);
        revenueCatRecordEventFacts($db,$event,'transferred');
        $db->commit();return ['received'=>true,'transferred'=>true];
    } catch(Throwable $error) { if($db->inTransaction())$db->rollBack();throw $error; }
}
