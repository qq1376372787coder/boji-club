<?php
declare(strict_types=1);

require_once __DIR__ . '/ai-response.php';
require_once __DIR__ . '/action-support.php';
require_once __DIR__ . '/onboarding-v2.php';
require_once __DIR__ . '/task-center.php';
require_once __DIR__ . '/context-continuation.php';
require_once __DIR__.'/ai-context.php';
require_once __DIR__ . '/export.php';
require_once __DIR__ . '/member-feedback.php';

$config = require dirname(__DIR__) . '/config.php';
require_once __DIR__ . '/media-quota.php';
require_once __DIR__ . '/media-store.php';

function respond(int $status, array $body = []): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function fail(string $message, int $status = 400): never {
    if ($GLOBALS['boji_domain_scope']??false) businessReject($status,['error'=>$message]);
    respond($status, ['error' => $message]);
}

/** Send the body first, then run non-critical maintenance after FPM releases the client. */
function respondThen(int $status, array $body, callable $after): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if (function_exists('fastcgi_finish_request')) fastcgi_finish_request();
    try { $after(); } catch (Throwable $error) { error_log('BOJI post-response task failed: ' . get_class($error)); }
    exit;
}

function body(int $maximum = 65536): array {
    $length = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($length > $maximum) fail('请求内容过大。', 413);
    $raw = file_get_contents('php://input');
    if ($raw === false || ($raw === '' && $length > 0)) fail('请求内容读取失败。');
    if (strlen($raw) > $maximum) fail('请求内容过大。', 413);
    if ($raw === '') return [];
    try {
        $value = json_decode($raw, true, 64, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        fail('请求格式不正确。');
    }
    if (!is_array($value)) fail('请求格式不正确。');
    return $value;
}

function rawBody(int $maximum): string {
    $length = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($length < 1 || $length > $maximum) fail('图片大小不符合要求。', 413);
    $raw = file_get_contents('php://input');
    if ($raw === false || strlen($raw) !== $length) fail('图片上传不完整。', 400);
    return $raw;
}

// Optional end-to-end trace supplied by a client that started an AI run.
// Validated shape only; never trusted for authorization.
$traceHeader = $_SERVER['HTTP_X_BOJI_TRACE'] ?? '';
if (is_string($traceHeader) && preg_match('/^[0-9a-f]{32}$/iD', $traceHeader)) {
    $GLOBALS['boji_trace_id'] = strtolower($traceHeader);
}

function mediaId(string $value): string {
    if (!preg_match('/^[0-9a-f-]{36}\.jpg$/i', $value)) fail('图片标识不正确。', 400);
    return strtolower($value);
}

function privateAiDelete(array $config, string $serverId): bool {
    $token = $config['ai_proxy_token'] ?? '';
    if (strlen($token) < 24 || !preg_match('/^[a-f0-9-]{36}$/i', $serverId)) return false;
    $context = stream_context_create(['http' => ['method' => 'DELETE', 'header' => "Authorization: Bearer " . $token . "\r\n", 'timeout' => 15, 'ignore_errors' => true, 'follow_location' => 0]]);
    $raw = @file_get_contents(privateAiBase($config) . '/v1/jobs/' . strtolower($serverId), false, $context);
    if ($raw === false) return false;
    foreach ($http_response_header ?? [] as $line) {
        if (preg_match('#^HTTP/\S+ (\d{3})#', $line, $match)) return (int)$match[1] === 200;
    }
    return false;
}


function removeMediaDirectory(int $userId): void {
    $directory = dirname(__DIR__) . '/media/' . $userId;
    if (!is_dir($directory) || is_link($directory)) return;
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($directory, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $entry) {
        if ($entry->isLink() || $entry->isFile()) @unlink($entry->getPathname());
        elseif ($entry->isDir()) @rmdir($entry->getPathname());
    }
    @rmdir($directory);
}

function respondImage(string $path, ?PDO $db = null, ?string $mediaLock = null): never {
    header('Content-Type: image/jpeg');
    header('Cache-Control: private, no-store');
    header('X-Content-Type-Options: nosniff');
    readfile($path);
    if ($db !== null && $mediaLock !== null) mediaStoreLockRelease($db, $mediaLock);
    exit;
}

function phone(array $input): string {
    $value = preg_replace('/\s+/', '', (string)($input['phone'] ?? ''));
    if (!preg_match('/^1[3-9]\d{9}$/', $value)) fail('请输入正确的中国大陆手机号。');
    return $value;
}

require __DIR__ . '/apple-auth.php';

function lockActiveUser(PDO $db, int $id): void {
    $lock = $db->prepare('SELECT status FROM users WHERE id=? FOR UPDATE'); $lock->execute([$id]);
    if ($lock->fetchColumn() !== 'active') { if ($db->inTransaction()) $db->rollBack(); fail('账号已停用，请重新登录。', 401); }
}

function bearer(): ?string {
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    return preg_match('/^Bearer\s+(.+)$/', $header, $match) ? trim($match[1]) : null;
}

function db(array $config): PDO {
    try {
        return new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    } catch (PDOException) {
        // The connection could not be opened, so there is no $db and no
        // transaction to roll back here. The previous catch block referenced
        // an undefined $db and crashed on the error path.
        fail('账号服务暂不可用。', 503);
    }
}

function authenticated(PDO $db): array {
    $token = bearer();
    if ($token === null || strlen($token) < 32) fail('登录已过期，请重新登录。', 401);
    $hash = hash('sha256', $token);
    $statement = $db->prepare('SELECT users.id, users.phone, users.apple_subject, users.status FROM sessions JOIN users ON users.id=sessions.user_id WHERE sessions.token_hash=? AND sessions.expires_at>UTC_TIMESTAMP() LIMIT 1');
    $statement->execute([$hash]);
    $user = $statement->fetch();
    if (!$user || $user['status'] !== 'active') fail('登录已过期，请重新登录。', 401);
    $db->prepare('UPDATE sessions SET last_used_at=UTC_TIMESTAMP() WHERE token_hash=? AND (last_used_at IS NULL OR last_used_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 60 SECOND))')->execute([$hash]);
    $user['token_hash'] = $hash;
    return $user;
}

function userPayload(PDO $db, int $id): array {
    $statement = $db->prepare('SELECT u.created_at AS account_created_at,u.phone,u.apple_subject,o.completed_at,o.plan_mode,p.nickname,p.gender,p.age,p.height_cm,p.weight_kg,p.goal,p.experience,p.venue,p.days_per_week,p.focus,p.equipment,p.equipment_other,p.session_minutes,p.limitations,p.training_days,p.home_training_days,m.status AS membership_status,m.source AS membership_source,m.plan_code,m.starts_at AS membership_starts_at,m.expires_at AS membership_expires_at FROM users u LEFT JOIN onboarding o ON o.user_id=u.id LEFT JOIN profiles p ON p.user_id=u.id LEFT JOIN membership_entitlements m ON m.user_id=u.id WHERE u.id=?');
    $statement->execute([$id]);
    $record = $statement->fetch() ?: [];
    $profile = null;
    if (isset($record['nickname'])) {
        $profile = [
            'nickname' => $record['nickname'], 'gender' => $record['gender'], 'age' => (int)$record['age'],
            'height' => (float)$record['height_cm'], 'weight' => (float)$record['weight_kg'],
            'goal' => $record['goal'], 'experience' => $record['experience'], 'venue' => $record['venue'],
            'daysPerWeek' => (int)$record['days_per_week'], 'focus' => $record['focus'],
            'equipment' => $record['equipment'], 'equipmentOther' => $record['equipment_other'],
            'sessionMinutes' => (int)$record['session_minutes'],
            'limitations' => $record['limitations'],
            'trainingDays' => $record['training_days'] === '' ? [] : array_map('intval', explode(',', $record['training_days'])),
            'homeTrainingDays' => $record['home_training_days'] === '' ? [] : array_map('intval', explode(',', $record['home_training_days'])),
        ];
        if (function_exists('profileFactsRead')) {
            $factDocument = profileFactsRead($db, $id);
            $factMap = [];
            foreach (($factDocument['facts'] ?? []) as $field => $fact) {
                $factMap[$field] = ['sourceKind' => (string)($fact['source_kind'] ?? 'legacy_recorded')];
            }
            if ((int)$factDocument['revision'] > 0 || $factMap !== []) {
                $profile['factState'] = $factMap === [] ? new stdClass() : $factMap;
            }
        }
    }
    if(function_exists('profileFactsRead')){
        $document=profileFactsRead($db,$id);
        if((int)$document['revision']>0){
            $base=$profile??['nickname'=>'薄肌成员','gender'=>null,'age'=>0,'height'=>0,'weight'=>0,'goal'=>'','experience'=>'','venue'=>'','daysPerWeek'=>0,'focus'=>'','equipment'=>null,'equipmentOther'=>null,'sessionMinutes'=>null,'limitations'=>null,'trainingDays'=>null,'homeTrainingDays'=>null];
            $profile=profileFactsOverlayStateProfile($base,is_array($document['facts'])?$document['facts']:[]);
        }
    }
    $phone = is_string($record['phone'] ?? null) ? $record['phone'] : '';
    $identity = is_string($record['apple_subject'] ?? null) && $record['apple_subject'] !== '' ? 'Apple ID 已连接' : (strlen($phone) === 11 ? substr($phone, 0, 3) . '****' . substr($phone, -4) : '会员账号');
    $membership = null;
    if (is_string($record['membership_status'] ?? null)) {
        $active = $record['membership_status'] === 'active' && strtotime((string)$record['membership_expires_at'] . ' UTC') > time();
        $lifetime = $record['membership_expires_at'] === '9999-12-31 23:59:59';
        $membership = ['active' => $active, 'source' => $record['membership_source'], 'plan_code' => $record['plan_code'], 'starts_at' => $record['membership_starts_at'], 'expires_at' => $lifetime ? null : $record['membership_expires_at'], 'lifetime' => $lifetime];
    }
    return [
        'id' => $id,
        'created_at' => isset($record['account_created_at']) ? gmdate('Y-m-d\TH:i:s\Z', strtotime($record['account_created_at'].' UTC')) : null,
        'phone_masked' => $identity,
        'club_number' => 'NO. ' . str_pad((string)(10000 + $id), 6, '0', STR_PAD_LEFT),
        'onboarding_completed' => isset($record['completed_at']) && $record['completed_at'] !== null,
        'profile' => $profile,
        'plan_mode' => $record['plan_mode'] ?? null,
        'membership' => $membership,
    ];
}

function cleanText(mixed $value, int $maximum): string {
    $value = trim((string)$value);
    if (mb_strlen($value) > $maximum) fail('填写内容过长，请精简后重试。');
    return $value;
}

require __DIR__.'/cloud-validation.php';
require_once __DIR__.'/cloud-parts.php';

function decodedState(array $input, bool $requireDays = true): array {
    $state = $input['state'] ?? null;
    cloudValidate($state,'state');
    if(!cloudWorkoutSessionsValid($state)) fail('当天多次训练的编号或时段不完整，请更新 App 并重新同步。',400);
    $days = is_array($state) ? ($state['days'] ?? null) : null;
    if (!is_array($state) || !isset($state['version']) || (int)$state['version'] !== 1
        || ($requireDays ? !is_array($days) : ($days !== null && !is_array($days)))) {
        fail('同步数据格式不正确。', 400);
    }
    $state=cloudNormalizeCycleOwnership($state);
    if (!is_array($state['profile'] ?? null) || !is_array($state['drafts'] ?? null) || !is_string($state['importedPlan'] ?? null)) fail('同步资料格式不完整。');
    foreach (['nickname', 'goal', 'experience', 'venue', 'focus'] as $key) {
        if (!is_string($state['profile'][$key] ?? null)) fail('个人资料字段不完整。');
    }
    foreach (['age', 'height', 'weight', 'daysPerWeek'] as $key) {
        if (!is_numeric($state['profile'][$key] ?? null)) fail('个人资料数值不正确。');
    }
    foreach (($state['days'] ?? []) as $date => $day) {
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', (string)$date) || !is_array($day)) fail('训练日期格式不正确。');
        foreach (['exercises', 'meals'] as $kind) {
            if (!is_array($day[$kind] ?? null) || !array_is_list($day[$kind])) fail('训练或饮食列表格式不正确。');
            $seen = [];
            foreach ($day[$kind] as $item) {
                if (!is_array($item) || !is_string($item['id'] ?? null) || !preg_match('/^[0-9a-f-]{36}$/i', $item['id']) || isset($seen[strtolower($item['id'])])) fail('记录编号不正确或重复。');
                $seen[strtolower($item['id'])] = true;
                if ($kind === 'meals') {
                    foreach (['photoFilename', 'photoRemoteID'] as $field) {
                        if (isset($item[$field])) mediaId((string)$item[$field]);
                    }
                }
            }
        }
    }
    if (isset($state['deletedMediaIDs']) && (!is_array($state['deletedMediaIDs']) || !array_is_list($state['deletedMediaIDs']))) fail('图片删除列表不正确。');
    foreach (($state['deletedMediaIDs'] ?? []) as $id) mediaId((string)$id);
    // Empty Swift dictionaries must remain JSON objects, never PHP's empty list [].
    foreach ($state['days'] ?? [] as &$day) { if (isset($day['weeklyReview']['baseline'])) $day['weeklyReview']['baseline'] = (object)$day['weeklyReview']['baseline']; }
    unset($day);
    foreach (($state['aiJobs'] ?? []) as $index=>$job) { $state['aiJobs'][$index]['request']['payload']=(object)$job['request']['payload']; }
    if ($requireDays || isset($state['days'])) $state['days'] = (object)$state['days'];
    $encoded = json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    if (strlen($encoded) > 16 * 1024 * 1024) fail('同步数据过大，请减少本地草稿后重试。', 413);
    return [$state, $encoded];
}



function clubState(PDO $db,int $userId): array {
    [$start,$end]=$GLOBALS['bojiClubProgressWindow']??['0000-00-00','9999-12-31'];
    return cloudStoredState($db,$userId,$start,$end,true,true);
}

require __DIR__ . '/club-progress.php';
require __DIR__ . '/club-artwork.php';

function clubPayload(PDO $db, int $userId, array $season, ?array $state=null): array {
    $counts = clubProgress($db, $userId, $season, $state);
    $statement = $db->prepare('SELECT id,title,detail,metric,target FROM club_tasks WHERE season_id=? ORDER BY sort_order,id');
    $statement->execute([(int)$season['id']]);
    $tasks = [];
    $taskDone = [];
    foreach ($statement->fetchAll() as $task) {
        $current = min((int)$task['target'], (int)($counts[$task['metric']] ?? 0));
        $done = $current >= (int)$task['target'];
        $taskDone[(int)$task['id']] = $done;
        $tasks[] = ['id' => (int)$task['id'], 'title' => $task['title'], 'detail' => $task['detail'],
            'metric' => $task['metric'], 'target' => (int)$task['target'], 'current' => $current, 'completed' => $done];
    }
    $joined = $db->prepare('SELECT joined_at FROM club_enrollments WHERE season_id=? AND user_id=?');
    $joined->execute([(int)$season['id'], $userId]);
    $enrollment = $joined->fetch();
    $statement = $db->prepare('SELECT r.id,r.task_id,r.title,r.detail,r.reward_type,r.icon,r.image_path,r.inventory,r.max_per_user,r.claim_deadline,c.status AS claim_status,c.tracking_company,c.tracking_number,c.shipped_at FROM club_rewards r LEFT JOIN club_reward_claims c ON c.reward_id=r.id AND c.user_id=? WHERE r.season_id=? ORDER BY r.sort_order,r.id');
    $statement->execute([$userId, (int)$season['id']]);
    $grants=$db->prepare('SELECT reward_id FROM club_virtual_grants WHERE user_id=? AND season_id=?');
    $grants->execute([$userId,(int)$season['id']]);
    $earnedRewards=array_fill_keys(array_map('intval',$grants->fetchAll(PDO::FETCH_COLUMN)),true);
    $rewardRows = $statement->fetchAll();
    $seasonClaim = $db->prepare("SELECT reward_id FROM club_reward_claims WHERE season_id=? AND user_id=? AND status<>'cancelled' LIMIT 1");
    $seasonClaim->execute([(int)$season['id'],$userId]);
    $claimedRewardId = $seasonClaim->fetchColumn();
    $rewards = [];
    foreach ($rewardRows as $reward) {
        $unlocked = $reward['reward_type'] === 'physical'
            ? (count($taskDone) > 0 && !in_array(false, $taskDone, true))
            : !empty($taskDone[(int)$reward['task_id']]);
        if ($enrollment && $unlocked && $reward['reward_type'] !== 'physical') {
            $grant = $db->prepare('INSERT IGNORE INTO club_virtual_grants(user_id,reward_id,season_id,granted_at) VALUES(?,?,?,UTC_TIMESTAMP())');
            $grant->execute([$userId, (int)$reward['id'], (int)$season['id']]);
        }
        $rewards[] = array_merge(['id' => (int)$reward['id'], 'task_id' => (int)$reward['task_id'],
            'unlock_scope' => $reward['reward_type'] === 'physical' ? 'season' : 'task', 'title' => $reward['title'], 'detail' => $reward['detail'],
            'type' => $reward['reward_type'], 'icon' => $reward['icon'], 'unlocked' => $unlocked || isset($earnedRewards[(int)$reward['id']]),
            'claim_status' => $reward['claim_status'], 'blocked_by_other_claim' => $claimedRewardId !== false && (int)$claimedRewardId !== (int)$reward['id'], 'tracking_company' => $reward['tracking_company'],
            'tracking_number' => $reward['tracking_number'], 'image_path' => $reward['image_path'],
            'shipped_at'=>$reward['shipped_at'],'max_per_user' => (int)($reward['max_per_user'] ?? 1), 'claim_deadline' => $reward['claim_deadline'] ?? (new DateTimeImmutable($season['ends_on']))->modify('+30 days')->format('Y-m-d')], clubArtworkMetadata($reward['image_path']));
    }
    $enrolledCount = $db->prepare('SELECT COUNT(*) FROM club_enrollments WHERE season_id=?');
    $enrolledCount->execute([(int)$season['id']]);
    $updates = $db->prepare('SELECT id,title,body,published_at FROM club_announcements WHERE season_id=? ORDER BY published_at DESC,id DESC LIMIT 20');
    $updates->execute([(int)$season['id']]);
    return [
        'season' => ['id' => (int)$season['id'], 'slug' => $season['slug'], 'title' => $season['title'],
            'subtitle' => $season['subtitle'], 'official_note' => $season['official_note'], 'rules' => $season['rules_text'],
            'starts_on' => $season['starts_on'], 'ends_on' => $season['ends_on'], 'join_deadline' => $season['join_deadline'],
            'access_mode' => $season['access_mode']],
        'joined' => (bool)$enrollment, 'joined_at' => $enrollment['joined_at'] ?? null,
        'tasks' => $tasks, 'rewards' => $rewards, 'announcements' => $updates->fetchAll(),
        'member_count' => (int)$enrolledCount->fetchColumn(),
    ];
}

$db = db($config);
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$prefix = '/account/v1';
if (!str_starts_with($path, $prefix)) fail('接口不存在。', 404);
$path = substr($path, strlen($prefix)) ?: '/';

require __DIR__ . '/revenuecat.php';
    require __DIR__ . '/media-cleanup.php';
    require __DIR__ . '/account-deletion.php';
    require __DIR__ . '/club-lock.php';
    require __DIR__ . '/app-config.php';
    require_once __DIR__ . '/training-commands.php';
    require_once __DIR__ . '/ai-router.php';
require_once __DIR__ . '/action-sync.php';

try {
    if ($path === "/me/feedback" || str_starts_with($path,"/me/feedback/")) fbRoute128($db,authenticated($db),$method,$path);
    if ($method === 'GET' && $path === '/config') {
        $payload = appConfigPublished($db);
        $body = json_encode(['schema_version' => 1, ...$payload], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        $etag = '"' . hash('sha256', $body) . '"';
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: private, no-cache');
        header('ETag: ' . $etag);
        header('X-Config-Version: ' . (int)$payload['version']);
        if (($_SERVER['HTTP_IF_NONE_MATCH'] ?? '') === $etag) { http_response_code(304); exit; }
        echo $body;
        exit;
    }
    if (str_starts_with($path, '/club/') && !appFeatureEnabled($db, 'club_enabled')) fail('俱乐部活动暂未开放。', 503);
    if (str_starts_with($path,'/auth/code/') && ($config['sms_mode'] ?? '') === 'development' && !filter_var($config['allow_development_phone_auth'] ?? false,FILTER_VALIDATE_BOOLEAN)) {
        fail('开发手机号登录已关闭，请使用 Apple 登录。',403);
    }
    if ($method === 'POST' && $path === '/webhooks/revenuecat') {
        revenueCatWebhook($db, $config);
    }

    if($method==='POST' && $path==='/auth/apple/deletion-status') {
        $input=body();$subject=appleIdentity($db,$config,$input);
        $id=filter_var($input['account_id'] ?? null,FILTER_VALIDATE_INT);
        if(!$id || $id<1) fail('账号标识不正确。',400);
        $status=recoveredAppleDeletionStatus($db,$config,(int)$id,$subject);
        if($status!==null) respond(200,$status);
        fail('此 Apple 账号无法核对这份注销申请，请使用申请时的账号。较早申请仍需客服核对。',404);
    }

    if ($method === 'POST' && $path === '/auth/apple/verify') {
        $input=body(); $subject = appleIdentity($db, $config, $input);
        require_once __DIR__.'/apple-tokens.php';
        try { $appleTokens=appleAuthorizationTokens($config,$input,$subject); }
        catch(Throwable) { fail('Apple 授权确认失败，请重新登录。',503); }
        $db->beginTransaction();
        $statement = $db->prepare('INSERT INTO users(phone,apple_subject,status,created_at,updated_at) VALUES(NULL,?,"active",UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE updated_at=UTC_TIMESTAMP()');
        $statement->execute([$subject]);
        $statement = $db->prepare('SELECT id,status FROM users WHERE apple_subject=? FOR UPDATE');
        $statement->execute([$subject]);
        $user = $statement->fetch();
        if (!$user || $user['status'] !== 'active') { $db->rollBack(); fail('账号暂不可用，请联系客服。', 403); }
        if($appleTokens) $db->prepare('INSERT INTO apple_tokens(user_id,client_id,token_cipher,checked_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE client_id=VALUES(client_id),token_cipher=VALUES(token_cipher),checked_at=UTC_TIMESTAMP()')->execute([(int)$user['id'],$appleTokens['client_id'],$appleTokens['token_cipher']]);
        $accessToken = rtrim(strtr(base64_encode(random_bytes(48)), '+/', '-_'), '=');
        $db->prepare('INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES(?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 30 DAY))')->execute([(int)$user['id'], hash('sha256', $accessToken)]);
        $db->commit();
        respond(200, ['access_token' => $accessToken, 'user' => userPayload($db, (int)$user['id'])]);
    }

    if ($method === 'POST' && $path === '/auth/code/request') {
        $input = body();
        $phone = phone($input);
        $developmentPhones = $config['dev_phones'] ?? [$config['dev_phone'] ?? '18800000000', '18800000001'];
        if ($config['sms_mode'] === 'development' && !in_array($phone, $developmentPhones, true)) {
            fail('短信服务申请中，请使用已授权的开发测试手机号。', 403);
        }
        $statement = $db->prepare('SELECT requested_at, request_day, request_count FROM verification_codes WHERE phone=?');
        $statement->execute([$phone]);
        $previous = $statement->fetch();
        $today = gmdate('Y-m-d');
        if ($previous && strtotime($previous['requested_at'] . ' UTC') > time() - 60) fail('验证码发送太频繁，请稍后再试。', 429);
        $count = ($previous && $previous['request_day'] === $today) ? (int)$previous['request_count'] + 1 : 1;
        if ($count > 10) fail('今天获取验证码次数较多，请明天再试。', 429);
        if ($config['sms_mode'] !== 'development') fail('短信服务正在配置中，请稍后再试。', 503);
        $code = (string)random_int(100000, 999999);
        $hash = hash_hmac('sha256', $phone . ':' . $code, $config['otp_secret']);
        $statement = $db->prepare('INSERT INTO verification_codes(phone,code_hash,expires_at,attempts,requested_at,request_day,request_count,request_ip) VALUES(?,?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 5 MINUTE),0,UTC_TIMESTAMP(),?,?,?) ON DUPLICATE KEY UPDATE code_hash=VALUES(code_hash),expires_at=VALUES(expires_at),attempts=0,requested_at=VALUES(requested_at),request_day=VALUES(request_day),request_count=VALUES(request_count),request_ip=VALUES(request_ip)');
        $statement->execute([$phone, $hash, $today, $count, $_SERVER['REMOTE_ADDR'] ?? '']);
        $result = ['message' => '验证码已发送，5 分钟内有效。'];
        if ($config['sms_mode'] === 'development') $result['dev_code'] = $code;
        respond(200, $result);
    }

    if ($method === 'POST' && $path === '/auth/code/verify') {
        $input = body();
        $phone = phone($input);
        $code = (string)($input['code'] ?? '');
        if (!preg_match('/^\d{6}$/', $code)) fail('请输入 6 位验证码。');
        $db->beginTransaction();
        $statement = $db->prepare('SELECT * FROM verification_codes WHERE phone=? FOR UPDATE');
        $statement->execute([$phone]);
        $record = $statement->fetch();
        if (!$record || strtotime($record['expires_at'] . ' UTC') <= time()) { $db->rollBack(); fail('验证码已过期，请重新获取。', 401); }
        if ((int)$record['attempts'] >= 5) { $db->rollBack(); fail('验证码错误次数过多，请重新获取。', 429); }
        $expected = hash_hmac('sha256', $phone . ':' . $code, $config['otp_secret']);
        if (!hash_equals($record['code_hash'], $expected)) {
            $db->prepare('UPDATE verification_codes SET attempts=attempts+1 WHERE phone=?')->execute([$phone]);
            $db->commit();
            fail('验证码不正确。', 401);
        }
        $statement = $db->prepare('SELECT id,status FROM users WHERE phone=?');
        $statement->execute([$phone]);
        $user = $statement->fetch();
        if (!$user) {
            $db->prepare('INSERT INTO users(phone,status,created_at,updated_at) VALUES(?,"active",UTC_TIMESTAMP(),UTC_TIMESTAMP())')->execute([$phone]);
            $user = ['id' => (int)$db->lastInsertId(), 'status' => 'active'];
        } else {
            $db->prepare('UPDATE users SET updated_at=UTC_TIMESTAMP() WHERE id=?')->execute([(int)$user['id']]);
        }
        if (!$user || $user['status'] !== 'active') { $db->rollBack(); fail('账号暂不可用，请联系客服。', 403); }
        $accessToken = rtrim(strtr(base64_encode(random_bytes(48)), '+/', '-_'), '=');
        $db->prepare('INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES(?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 30 DAY))')->execute([(int)$user['id'], hash('sha256', $accessToken)]);
        $db->prepare('DELETE FROM verification_codes WHERE phone=?')->execute([$phone]);
        $db->commit();
        respond(200, ['access_token' => $accessToken, 'user' => userPayload($db, (int)$user['id'])]);
    }

    require __DIR__ . '/club-push.php';
    clubPushRoutes($db,$config,$method,$path);
    require __DIR__ . '/automation.php';
    clubAutomationRoutes($db,$config,$method,$path);
    // AI onboarding V2: facts and session state are server-authoritative.
    function onboardingJSON(callable $work): never {
        try { respond(200, $work()); }
        catch (RuntimeException $error) {
            $status = $error->getCode() >= 400 && $error->getCode() < 600 ? $error->getCode() : 500;
            if($status===500){error_log('BOJI onboarding failure: '.get_class($error));fail('资料服务暂时不可用，请稍后重试。',500);}
            fail($error->getMessage() !== '' ? $error->getMessage() : '请求未完成。', $status);
        }
    }
    if ($method === 'POST' && $path === '/me/onboarding/v2/checkpoints/basic-profile') {
        $user=authenticated($db);$input=body(4096);
        onboardingJSON(fn()=>onboardingSaveBasicStatus($db,$user,$input,onboardingKey()));
    }
    if ($method === 'GET' && $path === '/me/onboarding/v2') {
        $user = authenticated($db);
        onboardingJSON(fn() => onboardingState($db, (int)$user['id']));
    }
    if ($method === 'POST' && $path === '/me/onboarding/v2/sessions') {
        $user = authenticated($db);
        $body = body(65536);
        onboardingJSON(fn() => onboardingCreateSession($db, $user, $body, onboardingKey()));
    }
    if (preg_match('#^/me/onboarding/v2/sessions/([0-9a-f-]{36})/(draft|profile-preview|profile-confirm|defer|complete|plan-adopted)$#i', $path, $match)) {
        $user = authenticated($db);
        $sessionId = strtolower($match[1]);
        $action = $match[2];
        $body = body(65536);
        if ($action === 'draft') {
            if ($method !== 'PATCH') fail('不支持此操作。', 405);
            onboardingJSON(fn() => onboardingPatchDraft($db, $user, $sessionId, $body, onboardingKey()));
        }
        if ($action === 'profile-preview') {
            if ($method !== 'POST') fail('不支持此操作。', 405);
            onboardingJSON(fn() => onboardingPreview($db, $user, $sessionId, $body, onboardingKey()));
        }
        if ($action === 'profile-confirm') {
            if ($method !== 'POST') fail('不支持此操作。', 405);
            onboardingJSON(fn() => onboardingConfirm($db, $user, $sessionId, $body, onboardingKey()));
        }
        if ($action === 'defer') {
            if ($method !== 'POST') fail('不支持此操作。', 405);
            onboardingJSON(fn() => onboardingDefer($db, $user, $sessionId, $body, onboardingKey()));
        }
        if ($action === 'plan-adopted') {
            if ($method !== 'POST') fail('不支持此操作。', 405);
            onboardingJSON(fn() => onboardingPlanAdopted($db, $user, $sessionId, $body, onboardingKey()));
        }
        if ($method !== 'POST') fail('不支持此操作。', 405);
        onboardingJSON(fn() => onboardingComplete($db, $user, $sessionId, $body, onboardingKey()));
    }
    if ($method === 'GET' && preg_match('#^/me/profile-facts/proposals/([a-f0-9-]{36})$#i',$path,$m)) { $user=authenticated($db);onboardingJSON(fn()=>profileProposalPublic($db,(int)$user['id'],strtolower($m[1]))); }
    if ($method === 'GET' && $path === '/me/profile-facts') {
        $user = authenticated($db);
        $document = profileFactsRead($db, (int)$user['id']);
        $payload = profileFactsPublicDocument($document);
        if ($payload['facts'] === []) $payload['facts'] = new stdClass();
        respond(200, $payload + ['definitions' => profileFactDefinitionsPublic()]);
    }
    if ($method === 'POST' && $path === '/me/profile-facts/preview') {
        $user = authenticated($db);
        $body = body(65536);
        onboardingJSON(fn() => profileChangePreview($db, $user, $body, onboardingKey()));
    }
    if ($method === 'POST' && $path === '/me/profile-facts/confirm') {
        $user = authenticated($db);
        $body = body(65536);
        onboardingJSON(fn() => profileChangeConfirm($db, $user, $body, onboardingKey()));
    }
    if ($method === 'POST' && $path === '/me/profile-facts/dismiss') {
        $user=authenticated($db);$body=body(65536);onboardingJSON(fn()=>profileChangeDismiss($db,$user,$body,onboardingKey()));
    }
    if ($method === 'POST' && $path === '/me/profile-facts/clear') {
        $user = authenticated($db);
        $body = body(65536);
        onboardingJSON(fn() => profileFactsClear($db, $user, $body, onboardingKey()));
    }
    if ($method === 'GET' && $path === '/me/tasks') {
        $user = authenticated($db);
        try { respond(200, taskCenterPage($db, (int)$user['id'], $_GET)); }
        catch (RuntimeException $error) { fail($error->getMessage(), $error->getCode() >= 400 && $error->getCode() < 600 ? $error->getCode() : 500); }
    }
    if ($method === 'GET' && $path === '/me/ai/tasks') {
        // Legacy AI job recovery shape (id/date/created/purpose) kept separate
        // from the aggregate task center so AIService can still rebuild jobs.
        $user = authenticated($db);
        require_once __DIR__ . '/task-recovery.php';
        respond(200, taskRecoveryPage($db, (int)$user['id'], $config, $_GET));
    }
    if ($method === 'GET' && preg_match('#^/me/tasks/(ai_job|proposal|command|plan_draft|onboarding|profile_proposal)/([0-9a-f-]{36})$#i', $path, $match)) {
        $user = authenticated($db);
        try { respond(200, taskCenterDetail($db, (int)$user['id'], strtolower($match[1]), $match[2])); }
        catch (RuntimeException $error) { fail($error->getMessage(), $error->getCode() >= 400 && $error->getCode() < 600 ? $error->getCode() : 500); }
    }
    if ($method === 'GET' && $path === '/me/export') {
        $user = authenticated($db);
        respond(200, accountDataExport($db, (int)$user['id']));
    }

    require __DIR__ . '/weekly.php';
    require_once __DIR__ . '/ai-runs.php';
    // Phase 2 §3.1–3.3: durable run + SSE transport. POST only creates the run;
    // closing the stream never cancels it. SSE never grants a write.
    if($method==='POST'&&$path==='/me/ai/consent'){
        $user=authenticated($db);$input=body(4096);
        if(!is_bool($input['allowed']??null)||($input['notice_version']??'')!=='2026-10-26.deepseek-minimax-v1')fail('授权内容不正确。',422);
        aiProviderConsentSet($db,(int)$user['id'],$input['allowed']);
        respond(200,['allowed'=>$input['allowed'],'notice_version'=>$input['notice_version']]);
    }
    if ($method === 'POST' && $path === '/me/ai/context/resolve') {
        $user=authenticated($db);
        if(!appFeatureEnabled($db,'ai_context_references_v1'))fail('引用功能暂未开放。',503);
        try { respond(200,aiContextResolve($db,(int)$user['id'],body(524288),$config)); }
        catch(RuntimeException $e){fail($e->getMessage(),in_array($e->getCode(),[403,409,410,413,422,429,503],true)?$e->getCode():422);}
    }
    if ($method === 'POST' && preg_match('#^/me/ai/conversations/([A-Za-z0-9_-]{8,64})/runs$#', $path, $runMatch)) {
        $user = authenticated($db);
        if (function_exists('revenueCatRefreshIfDue')) revenueCatRefreshIfDue($db, $user, $config);
        $created = aiRunCreate($db, $user, $config, (string)$runMatch[1], body(5900000), $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? null);
        respond(202, $created);
    }
    if ($method === 'GET' && preg_match('#^/me/ai/runs/([0-9a-f-]{36})$#i', $path, $runMatch)) {
        $user = authenticated($db);
        respond(200, aiRunSnapshot($db, (int)$user['id'], strtolower($runMatch[1])));
    }
    if ($method === 'GET' && preg_match('#^/me/ai/runs/([0-9a-f-]{36})/events$#i', $path, $runMatch)) {
        $user = authenticated($db);
        $after = isset($_GET['after_seq']) ? filter_var($_GET['after_seq'], FILTER_VALIDATE_INT) : 0;
        if ($after === false || $after === null || $after < 0) $after = 0;
        $lastEvent = $_SERVER['HTTP_LAST_EVENT_ID'] ?? '';
        if (is_string($lastEvent) && ctype_digit($lastEvent)) $after = max($after, (int)$lastEvent);
        aiRunStream($db, (int)$user['id'], strtolower($runMatch[1]), (int)$after);
    }
    if ($method === 'POST' && preg_match('#^/me/ai/runs/([0-9a-f-]{36})/cancel$#i', $path, $runMatch)) {
        $user = authenticated($db);
        respond(200, aiRunCancel($db, (int)$user['id'], strtolower($runMatch[1])));
    }
    if ($method === 'GET' && $path === '/me/ai/ops/summary') {
        $user = authenticated($db);
        respond(200, aiRunOpsSummary($db, (int)$user['id']));
    }
    // Phase 2: AI Intent Router — five processing modes over the capability
    // registry (spec §3). The model may only REQUEST; routing re-validates.
    if ($method === 'POST' && $path === '/me/ai/resolve') {
        $user = authenticated($db);
        if (!appFeatureEnabled($db, 'ai_enabled')) fail('AI 能力暂未开放。', 503);
        fail('能力请求由已验证的对话结果提交；请使用对话或原生确认入口。',422);
    }
    if($method==='GET' && preg_match('#^/me/ai/actions/messages/([0-9a-f-]{36})$#i',$path,$m)){$user=authenticated($db);respond(200,actionMessageResults($db,(int)$user['id'],strtolower($m[1])));}
    if($method==='PUT' && preg_match('#^/me/ai/proposals/([0-9a-f-]{36})/meal-draft$#i',$path,$m)){$user=authenticated($db);respond(200,actionEditMealDraft($db,$user,strtolower($m[1]),body(65536)));}
    if($method==='POST' && preg_match('#^/me/ai/proposals/([0-9a-f-]{36})/discard-training$#i',$path,$m)){$user=authenticated($db);respond(200,actionDiscardTraining($db,$user,strtolower($m[1])));}
    if($method==='POST' && preg_match('#^/me/ai/proposals/([0-9a-f-]{36})/confirm$#i',$path,$m)){$user=authenticated($db);respond(200,actionConfirmProposal($db,$user,strtolower($m[1])));}
    if($method==='POST' && preg_match('#^/me/ai/actions/([0-9a-f-]{36})/undo$#i',$path,$m)){$user=authenticated($db);$r=businessScoped(fn()=>aiRouterUndo($db,$user,['command_id'=>strtolower($m[1])]));respond(200,['status'=>'completed','data'=>$r['result']]);}
    if($path==='/me/ai/action-preferences'){
      $user=authenticated($db);$uid=(int)$user['id'];
      if($method==='GET'){$p=actionPreferences($db,$uid);$p['fast_records']=(bool)$p['fast_records'];$p['proactive_learning']=(bool)($p['proactive_learning']??true);respond(200,$p);}
      if($method==='PUT'){
        $p=body(4096);
        if(!array_key_exists('proactive_learning',$p))$p['proactive_learning']=(bool)(actionPreferences($db,$uid)['proactive_learning']??true);
        if(!is_bool($p['fast_records']??null)||!is_bool($p['proactive_learning']??null)||!in_array($p['weight_unit']??null,['kg','lb'],true)||!in_array($p['time_zone']??null,DateTimeZone::listIdentifiers(),true))fail('偏好格式不正确。',422);
        $db->prepare('INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,proactive_learning,updated_at) VALUES(?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE fast_records=VALUES(fast_records),time_zone=VALUES(time_zone),weight_unit=VALUES(weight_unit),proactive_learning=VALUES(proactive_learning),updated_at=UTC_TIMESTAMP()')->execute([$uid,(int)$p['fast_records'],$p['time_zone'],$p['weight_unit'],(int)$p['proactive_learning']]);respond(200,$p);
      }
    }
    if($method==='POST' && preg_match('#^/me/ai/drafts/([0-9a-f-]{36})/preview$#i',$path,$m)){
      $user=authenticated($db);$uid=(int)$user['id'];$id=strtolower($m[1]);$body=body(1000000);
      $result=businessScoped(function()use($db,$user,$uid,$id,$body){
        $db->beginTransaction();try{
          lockActiveUser($db,$uid);$payload=actionPlanDraftPayload($db,$uid,['draft_id'=>$id]);
          if(($body['replace']??false)===true){$known=array_column($payload['sessions'],'date');foreach(array_keys($body['expected_days']??[]) as $date)if(!in_array($date,$known,true)&&!in_array($date,$payload['retained_dates']??[],true))$payload['sessions'][]=['date'=>$date,'label'=>'休息','exercises'=>[]];}
          $created=aiProposalCreate($db,$uid,'plan_activation',$payload,[],null,hash('sha256','native-preview/'.$uid.'/'.$id.'/'.($body['preview_id']??businessUUID())),24,$body['expected_days']??null);
          $stored=aiProposalFetch($db,$uid,$created['proposal_id']);$db->commit();
          return ['status'=>$created['status'],'proposal_id'=>$created['proposal_id'],'capability'=>'plan.activate_version','card'=>aiRouterCard(['card_type'=>'plan_activate_preview','title'=>'核对计划变更','payload'=>$stored['payload']+['proposal_id'=>$created['proposal_id'],'kind'=>'plan_activation','preview'=>$stored['payload']]],'proposal/'.$created['proposal_id'],$created['expires_at'])];
        }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
      });respond(200,$result);
    }
    if(preg_match('#^/me/ai/drafts/([0-9a-f-]{36})$#i',$path,$m)){
      $user=authenticated($db);$uid=(int)$user['id'];$id=strtolower($m[1]);
      $q=$db->prepare("SELECT result_json,request_json FROM ai_action_jobs WHERE user_id=? AND execution_id=? AND status='draft_ready'");$q->execute([$uid,$id]);$draft=$q->fetch(PDO::FETCH_ASSOC);if(!$draft)fail('草稿尚未准备好。',409);
      if($method==='GET')respond(200,['draft_id'=>$id,'result'=>json_decode($draft['result_json'],true),'request'=>json_decode($draft['request_json'],true),'hash'=>hash('sha256',$draft['result_json'])]);
      if($method==='PUT'){
        $b=body(1000000);$result=$b['result']??[];$sessions=$result['sessions']??[];
        foreach($sessions as &$session)$session['exercises']=businessScoped(fn()=>actionTrustedExercises($db,$uid,$session['exercises']??[]));unset($session);
        $valid=aiProposalPayloadValid('plan_activation',['draft_id'=>$id,'sessions'=>$sessions]);if(!$valid)fail('草稿内容不正确。',422);
        $result['sessions']=$valid['sessions'];$result['kind']='plan';$result['title']=mb_substr($result['title']??'新计划',0,80);$result['notes']=array_slice($result['notes']??[],0,12);
        $q=$db->prepare("UPDATE ai_action_jobs SET result_json=?,updated_at=UTC_TIMESTAMP() WHERE user_id=? AND execution_id=? AND SHA2(result_json,256)=?");$q->execute([json_encode($result,JSON_UNESCAPED_UNICODE),$uid,$id,$b['expected_hash']??'']);if(!$q->rowCount() && hash('sha256',$draft['result_json'])!==($b['expected_hash']??''))fail('草稿已在其他设备修改，请重新读取。',409);
        $savedRaw=json_encode($result,JSON_UNESCAPED_UNICODE);respond(200,['saved'=>true,'hash'=>hash('sha256',$savedRaw)]);
      }
    }
    if ($method === 'GET' && preg_match('#^/me/ai/actions/([0-9a-f-]{36})$#i', $path, $match)) {
        $user = authenticated($db);
        $status = aiRouterActionStatus($db, (int)$user['id'], strtolower($match[1]));
        respond(200, ['execution' => aiRouterStatusEnvelope($status['data'],strtolower($match[1]))]);
    }
    if ($method === 'GET' && $path === '/me/ai/projections') {
        $user = authenticated($db);
        respond(200, aiRouterProjectionStatus($db, (int)$user['id']));
    }
    if($method==='GET' && $path==='/me/storage') {
        $user=authenticated($db);respond(200,storageUsage($db,(int)$user['id']));
    }
    cloudPartRoutes($db,$config,$method,$path);

    if ($method === 'GET' && $path === '/me') {
        $user = authenticated($db);
        $payload = ['user' => userPayload($db, (int)$user['id'])];
        // A due RevenueCat check can take several seconds. Return the last
        // verified membership immediately, then refresh after the response.
        respondThen(200, $payload, fn() => revenueCatRefreshIfDue($db, $user, $config));
    }

    if ($method === 'POST' && $path === '/me/membership/verify') {
        $user = authenticated($db);
        if (body(1024) !== []) fail('会员核验无需提交账号或购买信息。',400);
        try { $state=revenueCatVerifyMembership($db,$user,$config,true); }
        catch(RevenueCatVerificationError $error) {
            error_log('BOJI membership verification: '.$error->reason);
            fail($error->reason==='rc_not_configured'?'会员核验服务尚未配置，请联系开发者。':'会员暂时未能核验，请稍后重新查询，不要重复付款。',503);
        }
        respond($state==='pending'?202:200,['user'=>userPayload($db,(int)$user['id']),'verification'=>$state]);
    }

    if (($method === 'DELETE' && $path === '/me') || ($method === 'GET' && $path === '/me/deletion')) {
        $queued=queuedAccountDeletion($db,bearer() ?? '');
        if($queued) respond($queued['status']==='completed'?200:202,['accepted'=>true,'deleted'=>$queued['status']==='completed','status'=>$queued['status']]);
        if($method==='GET') { authenticated($db); respond(200,['accepted'=>false]); }
        $input=body();
        if(($input['confirmation'] ?? '')!=='DELETE') fail('请确认注销账号。',400);
        $user=authenticated($db);
        enqueueAccountDeletion($db,$user,$config);
        respond(202,['accepted'=>true,'deleted'=>false,'status'=>'queued']);
    }

    if ($method==='GET' && $path==='/club/history') {
        $user=authenticated($db);
        $q=$db->prepare('SELECT s.* FROM club_seasons s JOIN club_enrollments e ON e.season_id=s.id WHERE e.user_id=? ORDER BY s.starts_on DESC LIMIT 100');$q->execute([(int)$user['id']]);
        $seasons=$q->fetchAll();$GLOBALS['bojiClubProgressWindow']=clubProgressWindow($seasons);$historyState=clubState($db,(int)$user['id']);
        $items=[];foreach($seasons as $season) $items[]=clubPayload($db,(int)$user['id'],$season,$historyState);
        respond(200,['items'=>$items]);
    }
    if ($method==='POST' && preg_match('#^/club/rewards/(\d+)/(cancel|received)$#',$path,$match)) {
        $user=authenticated($db);clubRulesLock($db);$db->beginTransaction();lockActiveUser($db,(int)$user['id']);
        $q=$db->prepare('SELECT * FROM club_reward_claims WHERE reward_id=? AND user_id=? FOR UPDATE');$q->execute([(int)$match[1],(int)$user['id']]);$claim=$q->fetch();
        if(!$claim){$db->rollBack();fail('申领记录不存在。',404);}
        if($match[2]==='cancel') {
            if(!empty($claim['shipped_at']) || !empty($claim['tracking_number']) || !in_array($claim['status'],['pending','confirmed','packing','problem'],true)){$db->rollBack();fail('该礼品已经发货或结束，无法取消。',409);}
            $status='cancelled';
        } else {
            if(empty($claim['shipped_at']) || !in_array($claim['status'],['shipped','problem'],true)){$db->rollBack();fail('请在礼品发货且实际收到后确认。',409);}
            $status='delivered';
        }
        $db->prepare('UPDATE club_reward_claims SET status=?,updated_at=UTC_TIMESTAMP() WHERE id=?')->execute([$status,(int)$claim['id']]);$db->commit();clubRulesUnlock($db);
        // The iOS client decodes ClubSeasonEnvelope for cancel/received; return
        // the refreshed season so the claim UI updates immediately.
        $q=$db->prepare('SELECT * FROM club_seasons WHERE id=?');$q->execute([(int)$claim['season_id']]);$season=$q->fetch();
        respond(200,$season?clubPayload($db,(int)$user['id'],$season):['season'=>null]);
    }

    if ($method === 'GET' && $path === '/club/current') {
        $user = authenticated($db);
        requireActiveMembership($db, $user, $config);
        $today = (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        $statement = $db->prepare("SELECT * FROM club_seasons WHERE status='published' AND starts_on<=? AND ends_on>=? ORDER BY starts_on DESC,id DESC LIMIT 1");
        $statement->execute([$today, $today]);
        $season = $statement->fetch();
        if (!$season) respond(200, ['season' => null]);
        respond(200, clubPayload($db, (int)$user['id'], $season));
    }

    if ($method === 'GET' && $path === '/club/collection') {
        $user = authenticated($db);
        $statement = $db->prepare('SELECT s.* FROM club_seasons s JOIN club_enrollments e ON e.season_id=s.id WHERE e.user_id=? ORDER BY s.starts_on DESC LIMIT 36');
        $statement->execute([(int)$user['id']]);
        $seasons=$statement->fetchAll();$GLOBALS['bojiClubProgressWindow']=clubProgressWindow($seasons);$collectionState=clubState($db,(int)$user['id']);
        foreach ($seasons as $season) clubPayload($db, (int)$user['id'], $season, $collectionState);
        $statement = $db->prepare("SELECT r.id,r.title,r.detail,r.icon,r.reward_type,r.image_path,s.title AS season_title,s.slug FROM club_virtual_grants g JOIN club_rewards r ON r.id=g.reward_id JOIN club_seasons s ON s.id=g.season_id WHERE g.user_id=? ORDER BY g.granted_at DESC LIMIT 100");
        $statement->execute([(int)$user['id']]);
        $items = $statement->fetchAll();
        foreach ($items as &$item) $item = array_merge($item, clubArtworkMetadata($item['image_path']));
        unset($item);
        respond(200, ['items' => $items]);
    }

    if ($method === 'POST' && preg_match('#^/club/seasons/(\d+)/join$#', $path, $match)) {
        $user = authenticated($db);
        requireActiveMembership($db, $user, $config);
        $seasonId = (int)$match[1];
        clubRulesLock($db);
        $db->beginTransaction();
        $today = (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        $statement = $db->prepare("SELECT * FROM club_seasons WHERE id=? AND status='published' AND starts_on<=? AND join_deadline>=? FOR UPDATE");
        $statement->execute([$seasonId, $today, $today]);
        $season = $statement->fetch();
        if (!$season) { $db->rollBack(); fail('本期成长季暂不可加入。', 409); }
        // Growth season access is included with the paid club membership; there is no separate season IAP.
        if ($season['access_mode'] !== 'included') {
            $db->prepare("UPDATE club_seasons SET access_mode='included',updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$seasonId]);
            $season['access_mode'] = 'included';
        }
        $existing = $db->prepare('SELECT 1 FROM club_enrollments WHERE season_id=? AND user_id=?');
        $existing->execute([$seasonId, (int)$user['id']]);
        if ($existing->fetchColumn()) { $db->commit(); clubRulesUnlock($db); respond(200, clubPayload($db, (int)$user['id'], $season)); }
        $count = $db->prepare('SELECT COUNT(*) FROM club_enrollments WHERE season_id=?');
        $count->execute([$seasonId]);
        if ($season['capacity'] !== null && (int)$count->fetchColumn() >= (int)$season['capacity']) { $db->rollBack(); fail('本期名额已满。', 409); }
        $statement = $db->prepare('INSERT IGNORE INTO club_enrollments(season_id,user_id,access_source,rules_version,joined_at) VALUES(?,?,' . "'included'" . ',?,UTC_TIMESTAMP())');
        $statement->execute([$seasonId, (int)$user['id'], $season['slug']]);
        $db->commit();
        clubRulesUnlock($db);
        respond(200, clubPayload($db, (int)$user['id'], $season));
    }

    if ($method === 'GET' && preg_match('#^/club/rewards/(\d+)/(image|image-info)$#', $path, $match)) {
        $user = authenticated($db);
        $statement = $db->prepare("SELECT image_path FROM club_rewards r JOIN club_seasons s ON s.id=r.season_id WHERE r.id=? AND (s.status='published' OR EXISTS(SELECT 1 FROM club_enrollments e WHERE e.season_id=s.id AND e.user_id=?))"); $statement->execute([(int)$match[1],(int)$user['id']]);
        $name = $statement->fetchColumn();
        $files = is_string($name) ? clubArtworkFiles($name) : null;
        if ($files === null) fail('图片不存在。',404);
        $metadata = clubArtworkMetadata($name);
        if ($match[2] === 'image-info') respond(200, $metadata);
        $version = $_GET['version'] ?? null;
        if (($version !== null && !is_string($version)) || !clubArtworkVersionMatches($metadata, $version)) fail('奖励图片已更新，请刷新后重试。',409);
        $thumbnail = ($_GET['size'] ?? '') === 'thumb';
        $file = $files[$thumbnail ? 'thumbnail' : 'full'];
        $mime = mime_content_type($file);
        if (!in_array($mime,['image/jpeg','image/png','image/webp'],true)) fail('图片格式不支持。',415);
        $data = file_get_contents($file);
        $checksum = $metadata[$thumbnail ? 'thumbnail_sha256' : 'image_sha256'];
        if ($data === false || !is_string($checksum) || !hash_equals($checksum, hash('sha256', $data))) fail('奖励图片正在更新，请稍后重试。',409);
        $etag = '"'.$checksum.'"';
        header('Content-Type: '.$mime); header('Cache-Control: private,no-store'); header('X-Content-Type-Options: nosniff');
        header('ETag: '.$etag); header('X-Artwork-Version: '.$metadata['image_version']); header('X-Content-SHA256: '.$checksum);
        if (($_SERVER['HTTP_IF_NONE_MATCH'] ?? '') === $etag) { http_response_code(304); exit; }
        echo $data; exit;
    }

    if ($method === 'POST' && preg_match('#^/club/rewards/(\d+)/claim$#', $path, $match)) {
        $user = authenticated($db);
        $input = body();
        $rewardId = (int)$match[1];
        $recipient = cleanText($input['recipient'] ?? '', 40);
        $contact = preg_replace('/\s+/', '', (string)($input['phone'] ?? ''));
        $region = cleanText($input['region'] ?? '', 100);
        $address = cleanText($input['address'] ?? '', 240);
        $size = cleanText($input['size'] ?? '', 20);
        if (mb_strlen($recipient) < 2 || !preg_match('/^1[3-9]\d{9}$/', $contact) || mb_strlen($region) < 2 || mb_strlen($address) < 5) fail('请完整填写收货信息。');
        // Progress may call the private AI metadata service. Never hold the
        // database-wide club rule lock across that outbound HTTP wait.
        $seasonWindow = $db->prepare("SELECT r.season_id,s.slug,s.starts_on,s.ends_on FROM club_rewards r JOIN club_seasons s ON s.id=r.season_id WHERE r.id=? AND s.status IN ('published','archived')");
        $seasonWindow->execute([$rewardId]);
        $seasonRow = $seasonWindow->fetch();
        $progress = $seasonRow ? clubProgress($db, (int)$user['id'], $seasonRow) : [];
        clubRulesLock($db);
        $db->beginTransaction();
        lockActiveUser($db, (int)$user['id']);
        $statement = $db->prepare("SELECT r.*,s.slug,s.starts_on,s.ends_on,s.status AS season_status,t.metric,t.target FROM club_rewards r JOIN club_seasons s ON s.id=r.season_id JOIN club_tasks t ON t.id=r.task_id WHERE r.id=? AND r.reward_type='physical' FOR UPDATE");
        $statement->execute([$rewardId]);
        $reward = $statement->fetch();
        if (!$reward || !in_array($reward['season_status'],['published','archived'],true)) { $db->rollBack(); fail('这个奖励暂不可申领。', 409); }
        $joined = $db->prepare('SELECT 1 FROM club_enrollments WHERE season_id=? AND user_id=?');
        $joined->execute([(int)$reward['season_id'], (int)$user['id']]);
        if (!$joined->fetchColumn()) { $db->rollBack(); fail('请先加入本期成长季。', 409); }
        $today = (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        $claimDeadline=$reward['claim_deadline'] ?? (new DateTimeImmutable($reward['ends_on']))->modify('+30 days')->format('Y-m-d');
        if ($today > $claimDeadline) { $db->rollBack(); fail('本期奖励已过申领截止日期。', 409); }
        $requirements = $db->prepare('SELECT metric,target FROM club_tasks WHERE season_id=?');
        $requirements->execute([(int)$reward['season_id']]);
        foreach ($requirements->fetchAll() as $requirement) {
            if ((int)($progress[$requirement['metric']] ?? 0) < (int)$requirement['target']) { $db->rollBack(); fail('完成本期全部成长任务后即可申领。', 409); }
        }
        $existing = $db->prepare('SELECT id,status FROM club_reward_claims WHERE reward_id=? AND user_id=? FOR UPDATE');
        $existing->execute([$rewardId, (int)$user['id']]);
        $previousClaim = $existing->fetch();
        if ($previousClaim && $previousClaim['status'] !== 'cancelled') { $db->rollBack(); fail('这个奖励已经提交过申领。', 409); }
        $seasonClaim = $db->prepare("SELECT 1 FROM club_reward_claims WHERE season_id=? AND user_id=? AND status<>'cancelled' LIMIT 1");
        $seasonClaim->execute([(int)$reward['season_id'], (int)$user['id']]);
        if ($seasonClaim->fetchColumn()) { $db->rollBack(); fail('本期实物奖励只能领取一件。', 409); }
        if ($reward['inventory'] !== null) {
            $used = $db->prepare("SELECT COUNT(*) FROM club_reward_claims WHERE reward_id=? AND status<>'cancelled'");
            $used->execute([$rewardId]);
            if ((int)$used->fetchColumn() >= (int)$reward['inventory']) { $db->rollBack(); fail('本期实物名额已满，请联系官方处理。', 409); }
        }
        if ($previousClaim) {
            $db->prepare("UPDATE club_reward_claims SET status='pending',reviewed_at=NULL,reviewed_by=NULL,recipient=?,phone=?,region=?,address=?,size_value=?,tracking_company=NULL,tracking_number=NULL,operator_note='',updated_at=UTC_TIMESTAMP() WHERE id=?")->execute([$recipient,$contact,$region,$address,$size === '' ? null : $size,(int)$previousClaim['id']]);
        } else {
            $db->prepare("INSERT INTO club_reward_claims(season_id,reward_id,user_id,status,recipient,phone,region,address,size_value,created_at,updated_at) VALUES(?,?,?,'pending',?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([(int)$reward['season_id'],$rewardId,(int)$user['id'],$recipient,$contact,$region,$address,$size === '' ? null : $size]);
        }
        $db->commit();
        clubRulesUnlock($db);
        $season = $db->prepare('SELECT * FROM club_seasons WHERE id=?');
        $season->execute([(int)$reward['season_id']]);
        respond(200, clubPayload($db, (int)$user['id'], $season->fetch()));
    }

    if ($method === 'GET' && $path === '/me/state') {
        $user = authenticated($db);
        $metadata=$db->prepare('SELECT revision FROM app_states WHERE user_id=?');$metadata->execute([(int)$user['id']]);
        $revision=(int)($metadata->fetchColumn() ?: 0);
        $known=filter_var($_GET['known_revision']??null,FILTER_VALIDATE_INT);
        if($known!==false && $known!==null && $known>=0 && $known===$revision) {
            respond(200,['revision'=>$revision,'state'=>null,'unchanged'=>true]);
        }
        $statement = $db->prepare('SELECT revision,state_json,updated_at FROM app_states WHERE user_id=?');
        $statement->execute([(int)$user['id']]);
        $record = $statement->fetch();
        if (!$record) respond(200, ['revision' => 0, 'state' => null]);
        $state = json_decode($record['state_json'], false, 64, JSON_THROW_ON_ERROR);
        if(($state->_partitioned??null)===2) {
            $state=cloudLegacyState($db,(int)$user['id']);$state['days']=(object)$state['days'];
        }
        respond(200, ['revision' => (int)$record['revision'], 'state' => $state, 'updated_at' => $record['updated_at']]);
    }

    if ($method === 'POST' && $path === '/me/commands') {
        $user = authenticated($db);
        require_once __DIR__ . '/commands.php';
        $result = handleBusinessCommand($db, $user);
        respond(200, $result);
    }

    if ($method === 'PUT' && $path === '/me/state') {
        $user = authenticated($db);
        $input = body(17 * 1024 * 1024);
        [$state, $encoded] = decodedState($input);
        $baseRevision = (int)($input['base_revision'] ?? -1);
        if ($baseRevision < 0) fail('同步版本不正确。');
        $db->beginTransaction();
        // Lock a row that exists even for the account's first concurrent upload.
        lockActiveUser($db, (int)$user['id']);
        $statement = $db->prepare('SELECT revision,state_json FROM app_states WHERE user_id=? FOR UPDATE');
        $statement->execute([(int)$user['id']]);
        $existing = $statement->fetch();
        $currentRevision = $existing ? (int)$existing['revision'] : 0;
        $partitioned=$existing && (json_decode($existing['state_json'],true)['_partitioned']??null)===2;
        if ($baseRevision !== $currentRevision) {
            $db->rollBack();
            $remote = $partitioned ? cloudLegacyState($db,(int)$user['id']) : ($existing ? json_decode($existing['state_json'], false, 64, JSON_THROW_ON_ERROR) : null);
            if(is_array($remote))$remote['days']=(object)$remote['days'];
            respond(409, ['error' => '云端记录已在其他设备更新。', 'revision' => $currentRevision, 'state' => $remote]);
        }
        $previousState = $partitioned ? cloudLegacyState($db,(int)$user['id']) : ($existing ? json_decode($existing['state_json'], true) : []);
        $state['profile']=cloudPreserveLegacyIdentity($state['profile'],$previousState['profile']??[]);
        $state=cloudPreserveLegacyExperience($state,$previousState);
        $state=cloudReconcileRecords($state,$previousState);
        cloudValidate($state,'state');
        if(!cloudExperienceValid($state)) { $db->rollBack(); fail('训练周期或饮食确认信息格式不正确，原记录已保留。',400); }
        if(!cloudWorkoutSessionsPreserved($previousState,$state)) {
            $db->rollBack();
            fail('云端已有同日多次训练。这次同步未覆盖原记录，请更新所有设备上的 App 后重试。',400);
        }
        // Phase 1: the single-active-session invariant also holds for legacy
        // full-state uploads (backfill / release / refuse a parallel session).
        // Compatibility import: an old client's full-state profile becomes
        // legacy_recorded facts (never "verified"), without overwriting any
        // field the member has already confirmed through V2.
        profileFactsImportLegacyProfile($db, (int)$user['id'], is_array($state['profile'] ?? null) ? $state['profile'] : [], 'legacy_recorded', 'cloud_sync');
        if (is_array($state['profile'] ?? null)) {
            $state['profile'] = profileFactsOverlayStateProfile($state['profile'], profileFactsRead($db, (int)$user['id'])['facts']);
        }
        $trainingGuardError = trainingGuardFullStateSync($db, (int)$user['id'], $state);
        if ($trainingGuardError !== null) {
            $db->rollBack();
            respond(409, ['error' => $trainingGuardError, 'conflict' => true, 'revision' => $currentRevision]);
        }
        $GLOBALS['boji_active_preflight']=true;
        foreach($state['days'] as $date=>&$day)actionGuardDayUpload($db,(int)$user['id'],(string)$date,$previousState['days'][$date]??[],$day,'legacy-'.hash('sha256',$baseRevision.':'.$encoded));unset($day);
        unset($GLOBALS['boji_active_preflight']);
        $deleted = array_merge($state['deletedMediaIDs'] ?? [], $previousState['deletedMediaIDs'] ?? []);
        $references = [];
        foreach ($state['days'] as $day) foreach ($day['meals'] as $meal) foreach (['photoFilename','photoRemoteID'] as $key) if (isset($meal[$key])) $references[] = strtolower($meal[$key]);
        $deletedMeals = array_map('strtolower', $state['deletedMealIDs'] ?? []);
        foreach (($previousState['days'] ?? []) as $day) foreach (($day['meals'] ?? []) as $meal) {
            if (in_array(strtolower((string)($meal['id'] ?? '')), $deletedMeals, true)) {
                foreach (['photoFilename','photoRemoteID'] as $key) if (isset($meal[$key]) && !in_array(strtolower($meal[$key]),$references,true)) $deleted[] = $meal[$key];
            }
        }
        $deleted = array_values(array_unique(array_map(fn($id) => mediaId((string)$id), $deleted)));
        $state['deletedMediaIDs'] = $deleted;
        foreach ($state['days'] as &$day) foreach ($day['meals'] as &$meal) {
            if (in_array(strtolower((string)($meal['photoRemoteID'] ?? $meal['photoFilename'] ?? '')), $deleted, true)) { unset($meal['photoRemoteID'], $meal['photoFilename']); }
        }
        unset($day, $meal);
        // Durable file cleanup is inserted before committing the deletion.
        foreach ($deleted as $id) {
            $insert=$db->prepare('INSERT IGNORE INTO deleted_media(user_id,media_id,deleted_at) VALUES(?,?,UTC_TIMESTAMP())');
            $insert->execute([(int)$user['id'],$id]);
            $db->prepare('DELETE FROM user_media WHERE user_id=? AND media_id=?')->execute([(int)$user['id'],$id]);
            $mediaDirectory=dirname(__DIR__).'/media/'.(int)$user['id'];
            if($insert->rowCount()>0 || mediaStoreResolve($mediaDirectory,$id)!==null || mediaStoreFiles($mediaDirectory,$id)!==[] || is_file(mediaStoreJournalPath($mediaDirectory,$id))) enqueueMediaCleanup($db,(int)$user['id'],$id);
        }
        $encoded = json_encode($state,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
        if(strlen($encoded)>16*1024*1024) { $db->rollBack(); fail('同步数据过大，原记录已保留。请减少本地草稿后重试。',413); }
        $nextRevision = $currentRevision + 1;
        $storedEncoded=$encoded;
        if($partitioned) {
            $db->prepare('DELETE FROM cloud_parts WHERE user_id=?')->execute([(int)$user['id']]);
            $db->prepare('DELETE FROM cloud_meal_sources WHERE user_id=?')->execute([(int)$user['id']]);
            $db->prepare('DELETE FROM cloud_media_refs WHERE user_id=?')->execute([(int)$user['id']]);
            $parts=cloudPartSplit($state);
            foreach($parts as $key=>$part)cloudPartPut($db,(int)$user['id'],$key,$part);
            $storedEncoded=json_encode(cloudPartMetadata($parts['meta']),JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
        }
        if ($existing) {
            $statement = $db->prepare('UPDATE app_states SET revision=?,state_json=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?');
            $statement->execute([$nextRevision, $storedEncoded, (int)$user['id']]);
        } else {
            $statement = $db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,?,?,UTC_TIMESTAMP())');
            $statement->execute([(int)$user['id'], $nextRevision, $storedEncoded]);
        }
        $db->commit();
        $pending=processMediaCleanup($db,(int)$user['id']);
        respond(200, ['revision' => $nextRevision, 'state' => $state,'media_cleanup_pending'=>$pending]);
    }

    if (preg_match('#^/me/media/([^/]+)$#', $path, $match)) {
        $user = authenticated($db);
        $id = mediaId($match[1]);
        $directory = dirname(__DIR__) . '/media/' . (int)$user['id'];
        $file = $directory . '/' . $id;
        if ($method === 'GET') {
            try { $mediaLock = mediaStoreLockAcquire($db, (int)$user['id'], $id); }
            catch (Throwable) { fail('图片存储暂不可用。', 503); }
            // Finish or roll back a replacement interrupted by a crash before serving.
            mediaStoreRecover($db, (int)$user['id'], $directory, $id, true);
            $statement = $db->prepare('SELECT media_id FROM user_media WHERE user_id=? AND media_id=?');
            $statement->execute([(int)$user['id'], $id]);
            $resolved = mediaStoreResolve($directory, $id);
            if (!$statement->fetch() || $resolved === null) fail('图片不存在。', 404);
            respondImage($resolved, $db, $mediaLock);
        }
        if ($method === 'PUT') {
            $raw = rawBody(4 * 1024 * 1024);
            $image = @getimagesizefromstring($raw);
            if (!$image || ($image[2] ?? 0) !== IMAGETYPE_JPEG || ($image[0] ?? 0) > 12000 || ($image[1] ?? 0) > 12000) fail('请上传有效的 JPG 图片。', 415);
            if (!is_dir($directory) && !mkdir($directory, 0750, true) && !is_dir($directory)) fail('图片存储暂不可用。', 503);
            try { $mediaLock = mediaStoreLockAcquire($db, (int)$user['id'], $id); }
            catch (Throwable) { fail('图片存储暂不可用。', 503); }
            mediaStoreRecover($db, (int)$user['id'], $directory, $id, true);
            $journal = null;
            try {
                $db->beginTransaction();
                lockActiveUser($db, (int)$user['id']);
                $quota = checkMediaQuota($db, (int)$user['id'], $id, strlen($raw), $config);
                $quota ??= storageDiskReserveProblem($directory,strlen($raw));
                if ($quota !== null) { $db->rollBack(); fail($quota['message'], $quota['status']); }
                $deleted = $db->prepare('SELECT 1 FROM deleted_media WHERE user_id=? AND media_id=?'); $deleted->execute([(int)$user['id'],$id]);
                if ($deleted->fetchColumn()) { $db->rollBack(); fail('这张图片已被删除。',410); }
                // The event row is the durable commit marker. It is inserted in
                // the same transaction as user_media, before the journal is written.
                $db->prepare('INSERT INTO media_upload_events(user_id,uploaded_at) VALUES(?,UTC_TIMESTAMP())')->execute([(int)$user['id']]);
                $eventID = (int)$db->lastInsertId();
                $journal = mediaStorePrepare($directory, $id, $raw, $eventID);
                $statement = $db->prepare('INSERT INTO user_media(user_id,media_id,byte_size,content_type,version_file,created_at,updated_at) VALUES(?,?,?,"image/jpeg",?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE byte_size=VALUES(byte_size),content_type=VALUES(content_type),version_file=VALUES(version_file),updated_at=UTC_TIMESTAMP()');
                $statement->execute([(int)$user['id'], $id, strlen($raw), $journal['version_file']]);
                $db->commit();
            } catch (Throwable $error) {
                if ($db->inTransaction()) $db->rollBack();
                if (is_array($journal)) mediaStoreAbort($directory, $journal);
                if ($error instanceof PDOException) fail('账号服务暂不可用。', 503);
                fail('图片保存失败。', 503);
            }
            // Commit succeeded; publish the immutable version through the pointer.
            mediaStoreComplete($directory, $journal, $db, (int)$user['id']); // @phan-suppress-current-line PhanTypeMismatchArgumentNullable
            mediaStoreLockRelease($db, $mediaLock);
            respond(200, ['media_id' => $id]);
        }
        fail('接口不存在。', 404);
    }

    if ($method === 'PUT' && $path === '/me/onboarding') {
        $user = authenticated($db);
        $input = body();
        $profile = $input['profile'] ?? null;
        if (!is_array($profile)) fail('个人资料不完整。');
        $nickname = cleanText($profile['nickname'] ?? '', 30);
        $gender = cleanText($profile['gender'] ?? '', 10);
        $age = (int)($profile['age'] ?? 0);
        $height = (float)($profile['height'] ?? 0);
        $weight = (float)($profile['weight'] ?? 0);
        $days = (int)($profile['daysPerWeek'] ?? 0);
        $minutes = (int)($profile['sessionMinutes'] ?? 45);
        if (!in_array($gender, ['男', '女'], true)) fail('请选择性别。');
        $venue = cleanText($profile['venue'] ?? '', 20);
        if (!in_array($venue, ['健身房', '在家', '两者都有'], true)) fail('请选择训练场地。');
        $equipment = $venue === '健身房' ? '' : cleanText($profile['equipment'] ?? '', 200);
        $equipmentOther = $venue === '健身房' ? '' : cleanText($profile['equipmentOther'] ?? '', 200);
        if ($venue !== '健身房' && $equipment === '') fail('请选择居家可用器械。');
        if ($nickname === '' || $age < 13 || $age > 100 || $height < 50 || $height > 250 || $weight < 20 || $weight > 400 || $days < 1 || $days > 7 || $minutes < 15 || $minutes > 180) fail('个人资料数值不正确。');
        $planMode = (string)($input['plan_mode'] ?? '');
        if (!in_array($planMode, ['generate_plan', 'parse_plan'], true)) fail('请选择计划方式。');
        $agreement = cleanText($input['covenant_version'] ?? '', 30);
        if ($agreement === '') fail('请先同意薄肌三大公约。');
        $trainingDays = array_values(array_unique(array_filter(array_map('intval', is_array($profile['trainingDays'] ?? null) ? $profile['trainingDays'] : []), fn($day) => $day >= 1 && $day <= 7)));
        sort($trainingDays);
        if (count($trainingDays) !== $days) fail('每周训练日数量不正确。');
        $homeTrainingDays = array_values(array_unique(array_filter(array_map('intval', is_array($profile['homeTrainingDays'] ?? null) ? $profile['homeTrainingDays'] : []), fn($day) => in_array($day, $trainingDays, true))));
        sort($homeTrainingDays);
        $goalText = cleanText($profile['goal'] ?? '', 30);
        $expText = cleanText($profile['experience'] ?? '', 20);
        $focusText = cleanText($profile['focus'] ?? '', 100);
        $limitText = cleanText($profile['limitations'] ?? '', 500);
        $db->beginTransaction();
        $statement = $db->prepare('INSERT INTO profiles(user_id,nickname,gender,age,height_cm,weight_kg,goal,experience,venue,days_per_week,focus,equipment,equipment_other,session_minutes,limitations,training_days,home_training_days,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE nickname=VALUES(nickname),gender=VALUES(gender),age=VALUES(age),height_cm=VALUES(height_cm),weight_kg=VALUES(weight_kg),goal=VALUES(goal),experience=VALUES(experience),venue=VALUES(venue),days_per_week=VALUES(days_per_week),focus=VALUES(focus),equipment=VALUES(equipment),equipment_other=VALUES(equipment_other),session_minutes=VALUES(session_minutes),limitations=VALUES(limitations),training_days=VALUES(training_days),home_training_days=VALUES(home_training_days),updated_at=UTC_TIMESTAMP()');
        $statement->execute([(int)$user['id'], $nickname, $gender, $age, $height, $weight, $goalText, $expText, $venue, $days, $focusText, $equipment, $equipmentOther, $minutes, $limitText, implode(',', $trainingDays), implode(',', $homeTrainingDays)]);
        $statement = $db->prepare('INSERT INTO onboarding(user_id,plan_mode,covenant_version,started_at,updated_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE plan_mode=VALUES(plan_mode),covenant_version=VALUES(covenant_version),updated_at=UTC_TIMESTAMP()');
        $statement->execute([(int)$user['id'], $planMode, $agreement]);
        // Same authoritative writer as V2: the old full form is an explicit
        // user confirmation, but it still enters through the facts domain.
        profileFactsImportLegacyProfile($db, (int)$user['id'], [
            'goal' => $goalText, 'experience' => $expText, 'venue' => $venue, 'focus' => $focusText,
            'daysPerWeek' => $days, 'sessionMinutes' => $minutes, 'height' => $height, 'weight' => $weight,
            'age' => $age, 'gender' => $gender, 'limitations' => $limitText,
            'equipment' => $equipment, 'trainingDays' => $trainingDays,
            'factState' => is_array($profile['factState'] ?? null) ? $profile['factState'] : null,
        ], 'confirmed', 'legacy_questionnaire');
        $stateStmt = $db->prepare('SELECT revision, state_json FROM app_states WHERE user_id=? FOR UPDATE');
        $stateStmt->execute([(int)$user['id']]);
        $stateRow = $stateStmt->fetch();
        if ($stateRow) {
            $decodedState = json_decode((string)$stateRow['state_json'], true);
            if (is_array($decodedState) && ($decodedState['_partitioned'] ?? null) !== 2) {
                $decodedState['profile'] = array_merge(is_array($decodedState['profile'] ?? null) ? $decodedState['profile'] : [], [
                    'nickname' => $nickname, 'gender' => $gender, 'age' => $age,
                    'height' => $height, 'weight' => $weight, 'goal' => $goalText,
                    'experience' => $expText, 'venue' => $venue, 'daysPerWeek' => $days,
                    'focus' => $focusText, 'equipment' => $equipment, 'equipmentOther' => $equipmentOther,
                    'sessionMinutes' => $minutes, 'limitations' => $limitText,
                    'trainingDays' => $trainingDays, 'homeTrainingDays' => $homeTrainingDays,
                ]);
                if (isset($decodedState['days'])) $decodedState['days'] = (object)$decodedState['days'];
                $reencoded = json_encode($decodedState, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                if (is_string($reencoded)) {
                    $db->prepare('UPDATE app_states SET state_json=?, updated_at=UTC_TIMESTAMP() WHERE user_id=?')->execute([$reencoded, (int)$user['id']]);
                }
            }
        }
        $db->commit();
        respond(200, ['user' => userPayload($db, (int)$user['id'])]);
    }

    if ($method === 'POST' && $path === '/me/onboarding/complete') {
        $user = authenticated($db);
        $statement = $db->prepare('SELECT user_id FROM onboarding WHERE user_id=?');
        $statement->execute([(int)$user['id']]);
        if (!$statement->fetch()) fail('请先完成个人资料和计划设置。', 409);
        $statement = $db->prepare('UPDATE onboarding SET completed_at=COALESCE(completed_at,UTC_TIMESTAMP()),updated_at=UTC_TIMESTAMP() WHERE user_id=?');
        $statement->execute([(int)$user['id']]);
        respond(200, ['user' => userPayload($db, (int)$user['id'])]);
    }

    if ($method === 'POST' && $path === '/auth/logout') {
        $user = authenticated($db);
        $db->prepare('DELETE FROM sessions WHERE token_hash=?')->execute([$user['token_hash']]);
        respond(200, []);
    }

    fail('接口不存在。', 404);
} catch (BusinessActionError $error) {
    if ($db->inTransaction()) $db->rollBack();
    respond($error->getCode(), $error->detail);
} catch (PDOException) {
    if ($db->inTransaction()) $db->rollBack();
    fail('账号服务暂不可用。', 503);
} catch (Throwable $error) {
    if ($db->inTransaction()) $db->rollBack();
    // Never log the message: it can contain user data. Keep a JSON error body
    // instead of a bare 500 that the iOS client cannot decode.
    error_log('BOJI account request failed: ' . get_class($error));
    fail('账号服务暂时不可用，请稍后重试。', 500);
}
