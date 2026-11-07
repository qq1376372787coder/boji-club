<?php
declare(strict_types=1);
require_once __DIR__.'/ai-consent.php';

/** Domain errors cross service boundaries; only the HTTP adapter sends a response. */
class BusinessActionError extends RuntimeException {
    public function __construct(public readonly array $detail, int $status) { parent::__construct((string)($detail['error'] ?? '操作未完成。'), $status); }
}
function businessReject(int $status, array $detail): never { throw new BusinessActionError($detail, $status); }
function businessScoped(callable $operation): mixed {
    $previous = $GLOBALS['boji_domain_scope'] ?? false;
    $GLOBALS['boji_domain_scope'] = true;
    try { return $operation(); } finally { $GLOBALS['boji_domain_scope'] = $previous; }
}
/** Carry server-owned parent identity into every child domain transaction. */
function actionWithParent(int $uid, string $message, callable $operation, ?string $leaseOwner = null): mixed {
    $previous = $GLOBALS['boji_action_parent'] ?? null;
    if ($leaseOwner === null && is_array($previous) && ($previous['user_id'] ?? null) === $uid && ($previous['message_id'] ?? null) === $message) $leaseOwner = $previous['lease_owner'] ?? null;
    $GLOBALS['boji_action_parent'] = ['user_id' => $uid, 'message_id' => $message, 'lease_owner'=>$leaseOwner];
    try { return $operation(); }
    finally { $GLOBALS['boji_action_parent'] = $previous; }
}
/** Caller holds the account lock; cancel takes account -> run in the same order. */
function actionAssertParentActive(PDO $db, int $uid): void {
    $parent = $GLOBALS['boji_action_parent'] ?? null;
    if (!is_array($parent) || ($parent['user_id'] ?? null) !== $uid) return;
    if (!$db->inTransaction()) throw new LogicException('parent_fence_requires_transaction');
    $q = $db->prepare('SELECT status,lease_owner,lease_expires_at,request_json FROM ai_runs WHERE user_id=? AND message_id=? FOR UPDATE');
    $q->execute([$uid, $parent['message_id']]);
    $run = $q->fetch(PDO::FETCH_ASSOC);
    $status = $run['status'] ?? null;
    if (in_array($status, ['cancelled', 'failed'], true)) {
        businessReject(409, ['error' => '该消息已停止，未执行后续操作。', 'code' => 'PARENT_RUN_CANCELLED']);
    }
    if (!empty($parent['lease_owner']) && (!$run || $status !== 'running' || !hash_equals((string)($run['lease_owner'] ?? ''), $parent['lease_owner']) || !$run['lease_expires_at'] || strtotime($run['lease_expires_at'].' UTC') < time())) {
        businessReject(409, ['error'=>'行动处理权已变化，请查询原消息状态。','code'=>'PARENT_LEASE_LOST']);
    }
    // Derive routing from the persisted server request, never a model call flag.
    $request=$run ? json_decode((string)$run['request_json'],true) : [];
    aiProviderConsentAssert($db,$uid,is_array($request['payload'] ?? null)?$request['payload']:[],true);
}
function actionUUID(string $seed): string {
    $hex = hash('sha256', $seed);
    return substr($hex,0,8).'-'.substr($hex,8,4).'-4'.substr($hex,13,3).'-a'.substr($hex,17,3).'-'.substr($hex,20,12);
}
function actionISO(?string $value): ?string {
    if (!$value) return null;
    return (new DateTimeImmutable($value, new DateTimeZone('UTC')))->format('Y-m-d\TH:i:s\Z');
}
function actionPreferences(PDO $db, int $uid): array {
    $q=$db->prepare('SELECT fast_records,time_zone,weight_unit,proactive_learning FROM user_action_preferences WHERE user_id=?');$q->execute([$uid]);
    $row=$q->fetch(PDO::FETCH_ASSOC);
    return $row ?: ['fast_records'=>false,'time_zone'=>'Asia/Shanghai','weight_unit'=>'kg','proactive_learning'=>true];
}
function actionToday(PDO $db,int $uid): string {
    $zone=actionPreferences($db,$uid)['time_zone'];
    return (new DateTimeImmutable('now',new DateTimeZone($zone)))->format('Y-m-d');
}
/** Legacy daily value is retained as a projection, never as the measurement identity. */
function actionMeasurementProject(array &$day): void {
    $deleted=array_map('strtolower',$day['deletedBodyMeasurementIDs']??[]);
    $rows=array_values(array_filter($day['bodyMeasurements']??[],fn($v)=>!in_array(strtolower($v['id']??''),$deleted,true)));
    usort($rows,fn($a,$b)=>[($a['recordedAt']??$a['updatedAt']??0),$a['updatedAt']??0,$a['id']]<=>[($b['recordedAt']??$b['updatedAt']??0),$b['updatedAt']??0,$b['id']]);
    $day['bodyMeasurements']=$rows;
    if ($rows) $day['bodyWeight']=$rows[count($rows)-1]; else unset($day['bodyWeight']);
}
function actionMeasurementMigrate(array &$day,string $date): void {
    if (!isset($day['bodyMeasurements'])) {
        $day['bodyMeasurements']=[];
        if (is_array($day['bodyWeight']??null) && isset($day['bodyWeight']['kilograms'])) {
            $old=$day['bodyWeight'];$old['id']=$old['id']??actionUUID('legacy-weight/'.$date.'/'.sprintf('%.6F',$old['recordedAt']??$old['updatedAt']).'/'.sprintf('%.1F',$old['kilograms']));
            $day['bodyMeasurements'][]=$old;
        }
    }
}
