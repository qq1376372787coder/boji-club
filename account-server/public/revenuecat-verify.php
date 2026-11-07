<?php
declare(strict_types=1);
require_once __DIR__ . '/revenuecat-snapshot-policy.php';
require_once __DIR__ . '/revenuecat-facts.php';

final class RevenueCatVerificationError extends RuntimeException {
    public function __construct(public readonly string $reason, public readonly int $retryAfter = 15) { parent::__construct($reason); }
}

function revenueCatVerificationConfigured(array $config): bool {
    return !empty($config['revenuecat_project_id']) && !empty($config['revenuecat_v2_entitlement_id']) &&
        is_array($config['revenuecat_v2_products'] ?? null) && !empty($config['revenuecat_api_v2_key_file']);
}

/** Fixed RevenueCat HTTPS origin. Credentials never follow a redirect or client URL. */
function revenueCatV2Batch(array $config, array $paths, float $deadline, bool $retryService = true): array {
    if (!function_exists('curl_multi_init')) throw new RevenueCatVerificationError('rc_transport_unavailable');
    $file = $config['revenuecat_api_v2_key_file'] ?? '';
    if (!is_string($file) || !is_file($file) || filesize($file) > 256) throw new RevenueCatVerificationError('rc_not_configured', 60);
    $key = trim((string)file_get_contents($file));
    if (!preg_match('/^sk_[A-Za-z0-9_-]{20,120}$/D', $key)) throw new RevenueCatVerificationError('rc_not_configured', 60);
    $remaining = (int)(($deadline - microtime(true)) * 1000);
    if ($remaining < 100) throw new RevenueCatVerificationError('rc_timeout');
    $multi = curl_multi_init(); $handles = []; $buffers = []; $retry = [];
    try {
        foreach ($paths as $name => $path) {
            if (!is_string($path) || !str_starts_with($path, '/v2/projects/') || preg_match('/[\r\n]/', $path)) throw new RevenueCatVerificationError('rc_invalid_path');
            $buffers[$name] = ''; $retry[$name] = 15;
            $handle = curl_init('https://api.revenuecat.com' . $path);
            curl_setopt_array($handle, [
                CURLOPT_HTTPHEADER=>['Authorization: Bearer '.$key, 'Accept: application/json'],
                CURLOPT_FOLLOWLOCATION=>false, CURLOPT_SSL_VERIFYPEER=>true, CURLOPT_SSL_VERIFYHOST=>2,
                CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS, CURLOPT_CONNECTTIMEOUT_MS=>min(2500,$remaining),
                CURLOPT_TIMEOUT_MS=>min(6000,$remaining), CURLOPT_USERAGENT=>'BOJI-Server-Membership/0.13.70',
                CURLOPT_WRITEFUNCTION=>static function($handle, string $chunk) use (&$buffers,$name): int {
                    if (strlen($buffers[$name]) + strlen($chunk) > 2*1024*1024) return 0;
                    $buffers[$name] .= $chunk; return strlen($chunk);
                },
                CURLOPT_HEADERFUNCTION=>static function($handle, string $line) use (&$retry,$name): int {
                    if (preg_match('/^Retry-After:\s*([0-9]+)/i', $line, $m)) $retry[$name] = min(300,max(5,(int)$m[1]));
                    return strlen($line);
                },
            ]);
            $handles[$name] = $handle; curl_multi_add_handle($multi,$handle);
        }
        do {
            $code = curl_multi_exec($multi,$running);
            if ($code !== CURLM_OK) throw new RevenueCatVerificationError('rc_transport');
            if ($running) {
                if (microtime(true) >= $deadline) throw new RevenueCatVerificationError('rc_timeout');
                if (curl_multi_select($multi,0.2) === -1) usleep(10000);
            }
        } while ($running);
        $responses = []; $retryPaths = [];
        foreach ($handles as $name=>$handle) {
            if (curl_errno($handle)) throw new RevenueCatVerificationError('rc_transport');
            $status = (int)curl_getinfo($handle,CURLINFO_HTTP_CODE);
            if ($status === 401 || $status === 403) throw new RevenueCatVerificationError('rc_credentials',60);
            if ($status === 429) throw new RevenueCatVerificationError('rc_rate_limited',$retry[$name]);
            if (in_array($status,[500,502,503,504],true) && $retryService && $deadline-microtime(true)>2) {
                $retryPaths[$name]=$paths[$name]; continue;
            }
            if (!in_array($status,[200,404],true)) throw new RevenueCatVerificationError('rc_service');
            try { $data = json_decode($buffers[$name],true,512,JSON_THROW_ON_ERROR); }
            catch (JsonException) { throw new RevenueCatVerificationError('rc_invalid_json'); }
            if (!is_array($data)) throw new RevenueCatVerificationError('rc_invalid_json');
            $responses[$name] = ['status'=>$status,'data'=>$data];
        }
        if ($retryPaths) $responses += revenueCatV2Batch($config,$retryPaths,$deadline,false);
        return $responses;
    } finally {
        foreach ($handles as $handle) { curl_multi_remove_handle($multi,$handle); curl_close($handle); }
        curl_multi_close($multi);
    }
}

function revenueCatCompleteList(array $config, array $first, string $base, ?string $environment, float $deadline): array {
    $rows = []; $page = $first; $seen = [];
    do {
        if (($page['object'] ?? '') !== 'list' || !is_array($page['items'] ?? null) || !array_is_list($page['items']) || !array_key_exists('next_page',$page)) throw new RevenueCatVerificationError('rc_invalid_list');
        foreach ($page['items'] as $item) {
            if (!is_array($item)) throw new RevenueCatVerificationError('rc_invalid_list');
            $rows[] = $item;
        }
        $next = $page['next_page'];
        if ($next === null) break;
        if (!is_string($next) || $next === '') throw new RevenueCatVerificationError('rc_invalid_page');
        $parts = parse_url($next);
        if ($parts === false || ($parts['path'] ?? '') !== $base || isset($parts['user']) || isset($parts['pass']) ||
            (isset($parts['scheme']) && $parts['scheme'] !== 'https') || (isset($parts['host']) && $parts['host'] !== 'api.revenuecat.com') ||
            (isset($parts['port']) && $parts['port'] !== 443)) throw new RevenueCatVerificationError('rc_invalid_page');
        parse_str($parts['query'] ?? '',$query);
        $cursor = $query['starting_after'] ?? null;
        if (!is_string($cursor) || $cursor === '' || strlen($cursor)>255 || isset($seen[$cursor])) throw new RevenueCatVerificationError('rc_invalid_page');
        $seen[$cursor] = true;
        $parameters = ['limit'=>100,'starting_after'=>$cursor];
        if ($environment !== null) $parameters['environment'] = $environment;
        $response = revenueCatV2Batch($config,['next'=>$base.'?'.http_build_query($parameters,'','&',PHP_QUERY_RFC3986)],$deadline)['next'];
        if ($response['status'] !== 200) throw new RevenueCatVerificationError('rc_incomplete_list');
        $page = $response['data'];
    } while (true);
    return $rows;
}

function revenueCatFetchSnapshot(array $config, int $userID, int $observedMS): array {
    $project = (string)($config['revenuecat_project_id'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/D',$project)) throw new RevenueCatVerificationError('rc_not_configured');
    $base = '/v2/projects/'.$project.'/customers/boji-'.$userID;
    $environment = strtolower((string)($config['revenuecat_environment'] ?? 'PRODUCTION'));
    if (!in_array($environment,['sandbox','production'],true)) throw new RevenueCatVerificationError('rc_not_configured');
    $deadline = microtime(true)+12;
    $paths = ['customer'=>$base,'subscriptions'=>$base.'/subscriptions?limit=100&environment='.$environment,
        'purchases'=>$base.'/purchases?limit=100&environment='.$environment,'entitlements'=>$base.'/active_entitlements?limit=100'];
    $responses = revenueCatV2Batch($config,$paths,$deadline);
    if ($responses['customer']['status'] === 404) {
        foreach (['subscriptions','purchases','entitlements'] as $name) {
            if ($responses[$name]['status'] === 200 && !empty($responses[$name]['data']['items'])) throw new RevenueCatVerificationError('rc_inconsistent_customer');
        }
        return ['active'=>false,'product_id'=>'','starts_at'=>null,'expires_at'=>null,'purchase_id'=>null];
    }
    $lists = [];
    foreach (['subscriptions'=>'subscriptions','purchases'=>'purchases','entitlements'=>'active_entitlements'] as $name=>$resource) {
        if ($responses[$name]['status'] !== 200) throw new RevenueCatVerificationError('rc_incomplete_customer');
        $lists[$name] = revenueCatCompleteList($config,$responses[$name]['data'],$base.'/'.$resource,$name==='entitlements'?null:$environment,$deadline);
    }
    try { return revenueCatSnapshotPolicy($responses['customer']['data'],$lists['subscriptions'],$lists['purchases'],$lists['entitlements'],$config,$userID,$observedMS); }
    catch (UnexpectedValueException) { throw new RevenueCatVerificationError('rc_invalid_snapshot'); }
}

/** Short per-account request coalescing; never performs HTTP while holding DB locks. */
function revenueCatVerifyMembership(PDO $db, array $user, array $config, bool $force = false, ?callable $fetch = null): string {
    if (!revenueCatVerificationConfigured($config)) throw new RevenueCatVerificationError('rc_not_configured',60);
    $userID=(int)$user['id']; $attempt=bin2hex(random_bytes(16)); $observedMS=(int)floor(microtime(true)*1000);
    $db->beginTransaction();
    try {
        lockActiveUser($db,$userID);
        $db->prepare('INSERT IGNORE INTO revenuecat_member_checks(user_id) VALUES(?)')->execute([$userID]);
        $q=$db->prepare('SELECT * FROM revenuecat_member_checks WHERE user_id=? FOR UPDATE'); $q->execute([$userID]); $previous=$q->fetch(PDO::FETCH_ASSOC);
        $age=$force?5:300;
        if ($previous['verified_at'] !== null && strtotime($previous['verified_at'].' UTC')>time()-$age) { $db->commit(); return 'verified'; }
        if (($previous['attempt_started_at'] !== null && strtotime($previous['attempt_started_at'].' UTC')>time()-20) ||
            ($previous['next_attempt_at'] !== null && strtotime($previous['next_attempt_at'].' UTC')>time())) { $db->commit(); return 'pending'; }
        $db->prepare('UPDATE revenuecat_member_checks SET attempt_token=?,attempt_started_at=UTC_TIMESTAMP(),last_attempt_at=UTC_TIMESTAMP() WHERE user_id=?')->execute([$attempt,$userID]);
        $db->commit();
    } catch(Throwable $error) { if($db->inTransaction())$db->rollBack(); throw $error; }
    $failure=null; $snapshot=null;
    try { $snapshot=($fetch ?? 'revenueCatFetchSnapshot')($config,$userID,$observedMS); }
    catch(RevenueCatVerificationError $error) { $failure=$error; }
    catch(Throwable) { $failure=new RevenueCatVerificationError('rc_service'); }
    $db->beginTransaction();
    try {
        lockActiveUser($db,$userID);
        $q=$db->prepare('SELECT attempt_token FROM revenuecat_member_checks WHERE user_id=? FOR UPDATE'); $q->execute([$userID]);
        if ($q->fetchColumn() !== $attempt) { $db->commit(); return 'pending'; }
        if ($failure !== null) {
            $db->prepare('UPDATE revenuecat_member_checks SET attempt_token=NULL,attempt_started_at=NULL,last_error_code=?,next_attempt_at=? WHERE user_id=?')->execute([$failure->reason,gmdate('Y-m-d H:i:s',time()+$failure->retryAfter),$userID]);
            $db->commit(); throw $failure;
        }
        $db->prepare('UPDATE revenuecat_member_checks SET observed_at_ms=?,verified_at=UTC_TIMESTAMP(),verified_status=?,product_id=?,starts_at=?,expires_at=?,purchase_id=?,attempt_token=NULL,attempt_started_at=NULL,next_attempt_at=NULL,last_error_code=NULL WHERE user_id=?')->execute([$observedMS,$snapshot['active']?'active':'inactive',$snapshot['product_id'],$snapshot['starts_at'],$snapshot['expires_at'],$snapshot['purchase_id'],$userID]);
        revenueCatRecordCheckFacts($db,$config,$userID,$observedMS,$snapshot,$fetch === null);
        recomputeMembership($db,$userID); $db->commit(); return 'verified';
    } catch(Throwable $error) { if($db->inTransaction())$db->rollBack(); throw $error; }
}

function revenueCatRefreshIfDue(PDO $db, array $user, array $config): void {
    if (!revenueCatVerificationConfigured($config) || $db->inTransaction()) return;
    $q=$db->prepare("SELECT 1 FROM membership_entitlements WHERE user_id=? AND source='apple' UNION ALL SELECT 1 FROM revenuecat_member_checks WHERE user_id=? AND verified_at IS NOT NULL LIMIT 1");
    $q->execute([(int)$user['id'],(int)$user['id']]);
    if (!$q->fetchColumn()) return;
    try { revenueCatVerifyMembership($db,$user,$config); }
    catch(RevenueCatVerificationError $error) { error_log('BOJI membership verification: '.$error->reason); }
}

/** Invalidating only older observations lets delayed TRANSFER events stay harmless. */
function revenueCatInvalidateSnapshot(PDO $db, int $userID, int $eventTime): void {
    $db->prepare('UPDATE revenuecat_member_checks SET observed_at_ms=NULL,verified_at=NULL,verified_status=NULL WHERE user_id=? AND observed_at_ms<=?')->execute([$userID,$eventTime]);
    $db->prepare('UPDATE revenuecat_member_checks SET attempt_token=NULL,attempt_started_at=NULL WHERE user_id=? AND attempt_started_at<=?')->execute([$userID,revenueCatDate($eventTime)]);
}
