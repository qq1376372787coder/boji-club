<?php
declare(strict_types=1);
header('Cache-Control: no-store, private');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
ini_set('session.use_strict_mode', '1');
ini_set('session.gc_maxlifetime', '43200');
session_name('boji_admin');
// Admin is always served over TLS in every supported topology (direct 443 or
// reverse proxy); an unrecognised proxy that hides HTTPS must not silently
// downgrade the cookie, so Secure is unconditional.
// secure 必须只在真实 HTTPS 下开启：CI/本地用 `php -S` 明文跑集成测试时，
// secure cookie 会被客户端丢弃 → session 丢失 → CSRF 403（CI 首跑根因）。
// php-fpm/apache 下 PHP_SAPI 永远不是 cli-server，生产行为不变。
session_set_cookie_params(['lifetime'=>0, 'path'=>'/admin/', 'secure'=>PHP_SAPI!=='cli-server', 'httponly'=>true, 'samesite'=>'Strict']);
session_start();
$_SESSION['csrf'] ??= bin2hex(random_bytes(32));
date_default_timezone_set('Asia/Shanghai');
$config = require dirname(__DIR__) . '/config.php';
try {
    $db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES=>false]);
} catch (Throwable) { http_response_code(503); exit('后台暂时无法连接数据库，请稍后重试。'); }

require_once dirname(__DIR__) . '/public/revenuecat.php';
require_once dirname(__DIR__) . '/public/club-lock.php';
require_once dirname(__DIR__) . '/public/club-push.php';
require_once dirname(__DIR__) . '/public/app-config.php';
require_once __DIR__.'/member-feedback.php';
require_once __DIR__.'/workspace.php';
require_once __DIR__.'/config-input.php';
require_once __DIR__.'/scheduled-notifications.php';
require_once __DIR__.'/alerts.php';

function h(mixed $value): string { return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function uploadedImageExtension(string $path, string $mime): string {
    if ($mime === 'image/jpeg') return 'jpg';
    if ($mime === 'image/png') return 'png';
    if ($mime === 'image/webp') return 'webp';
    throw new RuntimeException('图片仅支持 JPG、PNG 或 WebP。');
}

function saveCatalogImage(int $catalogId, array $file): ?string {
    if (($file['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) return null;
    if (($file['error'] ?? -1) !== UPLOAD_ERR_OK || (int)($file['size'] ?? 0) < 1 || (int)($file['size'] ?? 0) > 5 * 1024 * 1024) {
        throw new RuntimeException('徽章/礼品照片需为 5 MB 以内的图片。');
    }
    $info = @getimagesize((string)$file['tmp_name']);
    if($info && ($info[0]>8192 || $info[1]>8192 || $info[0]*$info[1]>20000000)) throw new RuntimeException('图片尺寸过大，请压缩到 2000 万像素以内。');
    $extension = match ($info['mime'] ?? '') {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        default => throw new RuntimeException('徽章/礼品照片仅支持 JPG、PNG 或 WebP。'),
    };
    $directory = dirname(__DIR__) . '/admin-media';
    if (!is_dir($directory) && !mkdir($directory, 0750, true) && !is_dir($directory)) throw new RuntimeException('奖励图片目录不可写。');
    $name = 'catalog-' . $catalogId . '-' . bin2hex(random_bytes(8)) . '.' . $extension;
    $target = $directory . '/' . $name;
    if (!move_uploaded_file((string)$file['tmp_name'], $target)) throw new RuntimeException('徽章/礼品照片保存失败。');
    chmod($target, 0640);
    return $name;
}

function catalogValues(array $row): array {
    return [
        'id' => (int)$row['id'], 'kind' => (string)$row['kind'], 'name' => (string)$row['name'],
        'detail' => (string)$row['detail'], 'icon' => (string)$row['icon'], 'image_path' => $row['image_path'] ?? null,
        'sku' => $row['sku'] ?? '', 'default_inventory' => $row['default_inventory'] ?? null,
        'max_per_user' => 1, 'claim_deadline' => $row['claim_deadline'] ?? null,
    ];
}

function saveRewardImage(int $seasonId, int $rewardId, array $file): ?string {
    if (($file['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) return null;
    if (($file['error'] ?? -1) !== UPLOAD_ERR_OK || (int)($file['size'] ?? 0) < 1 || (int)($file['size'] ?? 0) > 5 * 1024 * 1024) {
        throw new RuntimeException('实物礼品照片需为 5 MB 以内的图片。');
    }
    $info = @getimagesize((string)$file['tmp_name']);
    if($info && ($info[0]>8192 || $info[1]>8192 || $info[0]*$info[1]>20000000)) throw new RuntimeException('图片尺寸过大，请压缩到 2000 万像素以内。');
    $mime = $info['mime'] ?? (str_ends_with(strtolower((string)($file['name'] ?? '')), '.svg') ? 'image/svg+xml' : '');
    $extension = uploadedImageExtension((string)$file['tmp_name'], $mime);
    $directory = dirname(__DIR__) . '/admin-media';
    if (!is_dir($directory) && !mkdir($directory, 0750, true) && !is_dir($directory)) throw new RuntimeException('奖励图片目录不可写。');
    $name = 'season-' . $seasonId . '-reward-' . $rewardId . '-' . bin2hex(random_bytes(8)) . '.' . $extension;
    $target = $directory . '/' . $name;
    if (!move_uploaded_file((string)$file['tmp_name'], $target)) throw new RuntimeException('实物礼品照片保存失败。');
    chmod($target, 0640);
    return $name;
}

function badgePreview(array $reward, string $photoPage = 'catalog_photo'): void {
    $type = (string)($reward['reward_type'] ?? $reward['kind'] ?? 'badge');
    $icon = (string)($reward['icon'] ?? '');
    $id = (int)($reward['id'] ?? 0);
    $imagePath = (string)($reward['image_path'] ?? '');
    if ($imagePath !== '' && $id > 0) {
        $param = $photoPage === 'reward_photo' ? 'reward' : 'id';
        $url = '?p=' . rawurlencode($photoPage) . '&amp;' . $param . '=' . $id;
        echo '<div class="admin-badge-preview"><div class="admin-badge-stage"><div class="admin-badge asset"><img src="' . $url . '" alt=""></div></div><small>Club Keepsake</small></div>';
        return;
    }
    echo '<div class="admin-badge-preview"><div class="admin-badge-stage"><span class="muted">暂无奖励图片</span></div><small>Club Keepsake</small></div>';
}

function query(string $sql, array $args = []): PDOStatement { global $db; $q=$db->prepare($sql); $q->execute($args); return $q; }
function audit(string $action, ?int $target = null, string $detail = ''): void {
    query('INSERT INTO admin_audit(admin_id,action,target_user_id,detail,ip,created_at) VALUES(?,?,?,?,?,UTC_TIMESTAMP())', [$_SESSION['admin_id']??null,$action,$target,mb_substr($detail,0,500),$_SERVER['REMOTE_ADDR']??'']);
}

function adminAuditLabels(): array {
    return ['reply_member_feedback'=>'回复用户反馈','status_member_feedback'=>'更新反馈状态','login'=>'登录','login_failed'=>'登录失败','logout'=>'退出登录','view_user'=>'查看成员','disable_user'=>'禁用账号','enable_user'=>'恢复账号','adjust_membership'=>'调整会员权益','retry_ai'=>'重试 AI 任务','pause_ai'=>'暂停 AI 新任务','enable_ai'=>'恢复 AI 新任务','update_storage_capacity'=>'更新照片容量','update_ai_capacity'=>'更新 AI 容量','update_ai_provider'=>'更新 AI 接口','update_member_tags'=>'更新成员标签','add_member_note'=>'新增运营备注','change_password'=>'修改密码','pause_automation'=>'暂停自动跟进','resume_automation'=>'恢复自动跟进','rerun_automation'=>'手动重跑自动跟进','update_push_budget'=>'更新推送预算','block_push'=>'停发账号推送','unblock_push'=>'恢复账号推送','update_app_config'=>'保存配置草稿','publish_app_config'=>'发布配置','rollback_app_config'=>'恢复配置草稿','create_admin'=>'新增管理员','update_admin'=>'更新管理员','reset_admin_password'=>'重置管理员密码','archive_notification_template'=>'归档通知模板','archive_reward_catalog'=>'归档奖励目录','delete_club_task'=>'删除成长季任务','test_notification'=>'发送测试通知','review_club_claim'=>'人工核验奖励申领','update_club_claim'=>'更新履约状态','delete_club_season'=>'删除成长季','archive_club_season'=>'下架成长季','publish_club_season'=>'发布成长季','publish_club_announcement'=>'发布成长季动态','create_club_task'=>'新增成长季任务','retry_account_deletion'=>'重试注销任务','delete_user'=>'删除账号及个人数据','create_club_season'=>'创建成长季','update_club_season'=>'更新成长季','reward_catalog_create'=>'新增奖励库条目','reward_catalog_update'=>'更新奖励库条目','notification_template_create'=>'新增通知模板','notification_template_update'=>'更新通知模板','notification_plan_create'=>'新增通知计划','notification_plan_update'=>'更新通知计划','update_ai_router'=>'更新 AI 路由权重'];
}

function redirect(string $page = 'overview', string $extra = ''): never { $tab=(string)($_POST['ui_section']??''); if(isset(adminPanelOptions($page)[$tab])&&!str_contains($extra,'tab='))$extra.='&tab='.rawurlencode($tab); header('Location: /admin/?p='.rawurlencode($page).$extra, true, 303); header('Content-Length: 0'); exit; }
function flash(string $text): void { $_SESSION['flash']=$text; }
function csrf(): void {
    if (!hash_equals($_SESSION['csrf'], (string)($_POST['csrf']??''))) { http_response_code(403); exit('页面已过期，请刷新后重试。'); }
}
function csrfField(): void { echo '<input type="hidden" name="csrf" value="'.h($_SESSION['csrf']).'">'; }
function clubNumber(int $id): string { return 'NO. '.str_pad((string)(10000+$id),6,'0',STR_PAD_LEFT); }
function stamp(?string $value): string { return $value ? (new DateTimeImmutable($value,new DateTimeZone('UTC')))->setTimezone(new DateTimeZone('Asia/Shanghai'))->format('m-d H:i') : '—'; }
function stateOf(?string $value): array { $state=json_decode($value??'{}',true); return is_array($state) ? $state : []; }
function badge(string $status): string { $labels=['active'=>'正常','disabled'=>'已禁用','deleted'=>'已注销']; return '<span class="badge '.h($status).'">'.h($labels[$status]??$status).'</span>'; }
function safeNumber(mixed $value): string { return is_numeric($value) ? number_format((float)$value, 0) : '—'; }
function listValue(mixed $value): array { return is_array($value) ? $value : []; }
function backupStatus(): array {
    $raw=@file_get_contents(dirname(__DIR__).'/runtime/backup-status.json');
    $status=json_decode($raw?:'',true);
    return is_array($status) ? $status : [];
}
function memberTagOptions(): array { return ['新成员','需跟进','训练中断','饮食跟进','反馈待处理','特别关注']; }
function aiAdmin(string $path, string $method='GET', ?array $body=null): array {
    global $config;
    $token=(string)($config['ai_proxy_token']??'');
    if (strlen($token)<24) throw new RuntimeException('AI 管理服务尚未配置。');
    $headers="Accept: application/json\r\nAuthorization: Bearer {$token}\r\n";
    $options=['http'=>['method'=>$method,'header'=>$headers,'timeout'=>4,'ignore_errors'=>true]];
    if ($body!==null) { $options['http']['header'].="Content-Type: application/json\r\n"; $options['http']['content']=json_encode($body,JSON_THROW_ON_ERROR); }
    $base=$config['ai_proxy_base_url']??'http://127.0.0.1:8787';
    if(!is_string($base)||!preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D',$base)) throw new RuntimeException('AI 管理服务地址不正确。');
    $raw=@file_get_contents($base.$path,false,stream_context_create($options));
    if ($raw===false) throw new RuntimeException('AI 服务暂时不可用，请稍后重试。');
    $result=json_decode($raw,true);
    if (!is_array($result)) throw new RuntimeException('AI 服务返回异常。');
    $status=502; foreach($http_response_header??[] as $line) if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$m)) $status=(int)$m[1];
    if($status<200||$status>=300) throw new RuntimeException('AI 服务请求失败：'.mb_substr((string)($result['error']??'未知错误'),0,100));
    return $result;
}
function aiTaskMembers(array $items): array {
    $ids=[]; foreach($items as $item) if(is_array($item)&&isset($item['id'])&&preg_match('/^[a-f0-9-]{36}$/D',(string)$item['id'])) $ids[]=(string)$item['id'];
    if(!$ids) return [];
    $marks=implode(',',array_fill(0,count($ids),'?'));
    $rows=query('SELECT j.server_job_id,u.id,p.nickname FROM ai_user_jobs j JOIN users u ON u.id=j.user_id LEFT JOIN profiles p ON p.user_id=u.id WHERE j.server_job_id IN ('.$marks.')',$ids)->fetchAll();
    $result=[]; foreach($rows as $row) $result[$row['server_job_id']]=['id'=>(int)$row['id'],'name'=>$row['nickname']?:clubNumber((int)$row['id'])];
    return $result;
}

$admin = null;
if (isset($_SESSION['admin_id'])) {
    $admin = query('SELECT id,username,role,status,session_version FROM admin_accounts WHERE id=?',[(int)$_SESSION['admin_id']])->fetch() ?: null;
    if (!$admin || $admin['status'] !== 'active' || (int)$admin['session_version'] !== ($_SESSION['version']??0) || time()-($_SESSION['seen']??0)>1800 || time()-($_SESSION['started']??0)>43200) {
        unset($_SESSION['admin_id']); $admin=null;
    } else { $_SESSION['seen']=time(); }
}

function adminRoles(): array {
    return [
        'super_admin' => ['label'=>'超级管理员','pages'=>['*'],'scopes'=>['*']],
        'operator' => ['label'=>'运营管理员','pages'=>['feedback','overview','users','user','subscriptions','club','badges','gifts','shipping','notifications','ai','automation','push','storage','system','alerts','audit','settings'],
            'scopes'=>['club','content','notifications','notifications_send','ai','automation','push','storage','users_sensitive','users_support','shipping','self']],
        'content' => ['label'=>'内容管理员','pages'=>['overview','club','badges','gifts','notifications','settings'],'scopes'=>['content','notifications','self']],
        'support' => ['label'=>'客服支持','pages'=>['feedback','overview','users','user','shipping','settings'],'scopes'=>['users_support','shipping','self']],
        'readonly' => ['label'=>'只读审计','pages'=>['feedback','overview','users','user','club','badges','gifts','shipping','notifications','ai','automation','push','storage','system','alerts','audit','settings'],'scopes'=>['self']],
    ];
}
function adminRole(): string { global $admin; return (string)($admin['role'] ?? 'readonly'); }
function adminRoleLabel(?string $role=null): string { $roles=adminRoles(); return $roles[$role ?? adminRole()]['label'] ?? '未知角色'; }
function adminCanViewPage(string $page): bool {
    if (!$GLOBALS['admin']) return false;
    $roles=adminRoles(); $pages=$roles[adminRole()]['pages'] ?? [];
    return in_array('*',$pages,true) || in_array($page,$pages,true) || ($page==='user' && in_array('users',$pages,true));
}
function adminActionScope(string $action): string {
    if (in_array($action,['feedback_reply','feedback_status'],true)) return 'users_support';
    if (in_array($action,['logout','password'],true)) return 'self';
    if (str_starts_with($action,'admin_')) return 'admins';
    if (str_starts_with($action,'config_')) return 'config';
    if (in_array($action,['notification_test','notification_plan_publish','notification_plan_pause'],true)) return 'notifications_send';
    if ($action==='club_claim_status') return 'shipping';
    if (str_starts_with($action,'club_')) return 'club';
    if (str_starts_with($action,'reward_catalog_')) return 'content';
    if (str_starts_with($action,'notification_')) return 'notifications';
    if (in_array($action,['ai_control','ai_capacity','ai_provider_update','ai_router_update','retry_ai'],true)) return 'ai';
    if (str_starts_with($action,'automation_')) return 'automation';
    if (str_starts_with($action,'push_')) return 'push';
    if ($action==='storage_capacity') return 'storage';
    if (in_array($action,['status','membership_adjust','delete_user'],true)) return 'users_sensitive';
    if (in_array($action,['member_tags','member_note','deletion_retry'],true)) return 'users_support';
    return 'unclassified';
}
function adminCanWriteAction(string $action): bool {
    if (!$GLOBALS['admin']) return false;
    $roles=adminRoles(); $scopes=$roles[adminRole()]['scopes'] ?? [];
    if (in_array('*',$scopes,true)) return true;
    return in_array(adminActionScope($action),$scopes,true);
}
function requireAdminPage(string $page): void {
    if (!adminCanViewPage($page)) { http_response_code(403); header('Content-Type: text/plain; charset=utf-8'); exit('当前管理员角色无权访问此页面。'); }
}
function requireAdminWrite(string $action): void {
    if (!adminCanWriteAction($action)) { http_response_code(403); throw new RuntimeException('当前管理员角色无权执行此操作。'); }
}
$error = null;
if ($_SERVER['REQUEST_METHOD']==='POST') {
    csrf();
    $action=(string)($_POST['action']??'');
    try {
        if ($action==='login') {
            $username=mb_substr(trim((string)($_POST['username']??'')),0,60);
            $password=(string)($_POST['password']??'');
            // Throttle both an IP+username bucket and a global username bucket.
            // The second one prevents password spraying across many usernames.
            $buckets=[hash('sha256',($_SERVER['REMOTE_ADDR']??'').'|'.strtolower($username)),hash('sha256','user|'.strtolower($username))];
            $db->beginTransaction();
            $limited=false;
            foreach($buckets as $bucket){
                query('INSERT IGNORE INTO admin_login_limits(bucket,attempts,window_start) VALUES(?,0,UTC_TIMESTAMP())',[$bucket]);
                $limit=query('SELECT attempts,window_start FROM admin_login_limits WHERE bucket=? FOR UPDATE',[$bucket])->fetch();
                $fresh=strtotime($limit['window_start'].' UTC')>time()-900;
                if ($fresh && (int)$limit['attempts']>=8) $limited=true;
            }
            if ($limited) { $db->rollBack(); http_response_code(429); $error='尝试次数较多，请 15 分钟后再试。'; }
            else {
                foreach($buckets as $bucket){
                    $limit=query('SELECT attempts,window_start FROM admin_login_limits WHERE bucket=?',[$bucket])->fetch();
                    $fresh=strtotime($limit['window_start'].' UTC')>time()-900;
                    if ($fresh) query('UPDATE admin_login_limits SET attempts=attempts+1 WHERE bucket=?',[$bucket]);
                    else query('UPDATE admin_login_limits SET attempts=1,window_start=UTC_TIMESTAMP() WHERE bucket=?',[$bucket]);
                }
                $db->commit();
                $row=query('SELECT * FROM admin_accounts WHERE username=?',[$username])->fetch();
                static $dummyHash=null; $dummyHash??=password_hash(bin2hex(random_bytes(16)),PASSWORD_DEFAULT);
                $passwordOk=strlen($password)<=1024 && password_verify($password,$row['password_hash']??$dummyHash);
                if ($row && $passwordOk && $row['status']==='active') {
                    session_regenerate_id(true);
                    $_SESSION['admin_id']=(int)$row['id']; $_SESSION['version']=(int)$row['session_version'];
                    $_SESSION['started']=time(); $_SESSION['seen']=time(); $_SESSION['csrf']=bin2hex(random_bytes(32));
                    query('UPDATE admin_accounts SET last_login_at=UTC_TIMESTAMP() WHERE id=?',[$row['id']]);
                    foreach($buckets as $bucket) query('DELETE FROM admin_login_limits WHERE bucket=?',[$bucket]);
                    audit('login'); redirect();
                }
                audit('login_failed',null,'用户名：'.$username); $error=$row && $passwordOk ? '此管理员账号已停用。' : '账号或密码不正确。';
            }
        } else {
            if (!$admin) redirect('login');
            requireAdminWrite($action);
            if(array_key_exists('user_id',$_POST))$_POST['user_id']=(string)adminMemberId($_POST['user_id']);
            fbAdminPost128($db,$action);
            if(str_starts_with($action,'club_')) clubRulesLock($db);
            if ($action==='logout') {
                audit('logout'); $_SESSION=[]; session_destroy();
                setcookie('boji_admin','',['expires'=>time()-3600,'path'=>'/admin/','secure'=>PHP_SAPI!=='cli-server','httponly'=>true,'samesite'=>'Strict']); redirect('login');
            }
            if ($action==='delete_user') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if(!$id||$id<1||($_POST['confirm_id']??'')!==(string)$id||mb_strlen($reason)<2||mb_strlen($reason)>200)throw new RuntimeException('请输入目标用户数字 ID 并填写 2—200 字删除原因。');
                require_once __DIR__.'/../public/account-deletion.php';
                require_once __DIR__.'/../public/ai-response.php';
                enqueueAccountDeletion($db,['id'=>(int)$id],$config,true,fn()=>audit('delete_user',(int)$id,$reason));
                flash('删除任务已受理，登录已撤销；后台将清理个人数据、媒体和 AI 记录，可在此查看进度。');redirect('user','&id='.(int)$id);
            }
            if ($action==='deletion_retry') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if(!$id||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的人工处理说明。');
                $db->beginTransaction();
                $deletion=query("SELECT id,status FROM account_deletions WHERE user_id=? AND status<>'completed' FOR UPDATE",[$id])->fetch();
                if(!$deletion||$deletion['status']!=='failed') { $db->rollBack(); throw new RuntimeException('该注销任务不在失败待处理状态。'); }
                query("UPDATE account_deletions SET status='retrying',attempts=0,last_error_code=NULL,next_attempt=UTC_TIMESTAMP(),updated_at=UTC_TIMESTAMP() WHERE id=?",[(int)$deletion['id']]);
                audit('retry_account_deletion',(int)$id,$reason); $db->commit();
                flash('注销任务已重新排队，将立即重试。'); redirect('user','&id='.(int)$id);
            }
            if ($action==='status') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $target=(string)($_POST['status']??''); $expected=(string)($_POST['expected']??'');
                $reason=trim((string)($_POST['reason']??''));
                if (!$id || !in_array($target,['active','disabled'],true) || mb_strlen($reason)<2 || mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的操作原因。');
                $db->beginTransaction();
                $user=query('SELECT status FROM users WHERE id=? FOR UPDATE',[$id])->fetch();
                if (!$user || $user['status']==='deleted' || $user['status']!==$expected) { $db->rollBack(); throw new RuntimeException('账号状态已变化，请刷新后重试。'); }
                $deletion=query("SELECT 1 FROM account_deletions WHERE user_id=? AND status<>'completed' LIMIT 1",[$id])->fetchColumn();
                if($deletion) { $db->rollBack(); throw new RuntimeException('该账号已受理注销，普通恢复不能撤销删除流程。请等待注销处理完成。'); }
                query('UPDATE users SET status=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$target,$id]);
                if ($target==='disabled') query('DELETE FROM sessions WHERE user_id=?',[$id]);
                audit($target==='disabled'?'disable_user':'enable_user',(int)$id,$reason); $db->commit();
                flash($target==='disabled'?'账号已禁用，登录会话已撤销。':'账号已恢复，用户可重新登录。'); redirect('user','&id='.(int)$id);
            }
            if ($action==='membership_adjust') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $operation=(string)($_POST['operation']??'');
                $days=filter_var($_POST['days']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if(!$id||!in_array($operation,['grant','revoke'],true)||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的调整原因。');
                if($operation==='grant'&&(!$days||$days<1||$days>3650)) throw new RuntimeException('会员天数需在 1—3650 天之间。');
                $db->beginTransaction();
                if(!query('SELECT 1 FROM users WHERE id=? AND status="active" FOR UPDATE',[$id])->fetchColumn()) throw new RuntimeException('成员不存在或已停用。');
                $member=query('SELECT * FROM membership_entitlements WHERE user_id=? FOR UPDATE',[$id])->fetch();
                if(!query('SELECT 1 FROM users WHERE id=? AND status<>"deleted"',[$id])->fetchColumn()) { $db->rollBack(); throw new RuntimeException('成员不存在或已注销。'); }
                $previousStatus=$member['status']??null; $previousExpires=$member['expires_at']??null;
                $now=new DateTimeImmutable('now',new DateTimeZone('UTC'));
                if($operation==='grant') {
                    $stillActive=$member&&$member['status']==='active'&&strtotime($member['expires_at'].' UTC')>$now->getTimestamp();
                    $base=$stillActive?new DateTimeImmutable($member['expires_at'],new DateTimeZone('UTC')):$now;
                    $starts=$stillActive?$member['starts_at']:$now->format('Y-m-d H:i:s');
                    $expires=$base->modify('+'.$days.' days')->format('Y-m-d H:i:s');
                    query('INSERT INTO membership_entitlements(user_id,status,source,plan_code,starts_at,expires_at,updated_by,operator_note,created_at,updated_at) VALUES(?,"active","admin","annual",?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status="active",plan_code="annual",starts_at=VALUES(starts_at),expires_at=VALUES(expires_at),updated_by=VALUES(updated_by),operator_note=VALUES(operator_note),updated_at=UTC_TIMESTAMP()',[$id,$starts,$expires,$admin['id'],$reason]);
                    query('INSERT INTO membership_admin_grants(user_id,status,starts_at,expires_at,updated_at) VALUES(?,"active",?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE status="active",starts_at=VALUES(starts_at),expires_at=VALUES(expires_at),updated_at=UTC_TIMESTAMP()',[$id,$starts,$expires]);
                    recomputeMembership($db,(int)$id);
                    $action=$stillActive?'extend':'grant'; $nextStatus='active'; $nextExpires=$expires;
                } else {
                    if(!$member) { $db->rollBack(); throw new RuntimeException('该成员尚无可撤销的会员权益。'); }
                    $nextExpires=$now->format('Y-m-d H:i:s'); $nextStatus='revoked'; $action='revoke';
                    query('UPDATE membership_admin_grants SET status="revoked",expires_at=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?',[$nextExpires,$id]);
                    query('UPDATE membership_entitlements SET status="revoked",expires_at=?,updated_by=?,operator_note=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?',[$nextExpires,$admin['id'],$reason,$id]);
                    recomputeMembership($db,(int)$id);
                    $updated=query('SELECT status,expires_at FROM membership_entitlements WHERE user_id=?',[$id])->fetch();
                    $nextStatus=$updated['status']; $nextExpires=$updated['expires_at'];
                }
                query('INSERT INTO membership_adjustments(user_id,admin_id,action,previous_status,previous_expires_at,next_status,next_expires_at,reason,created_at) VALUES(?,?,?,?,?,?,?,?,UTC_TIMESTAMP())',[$id,$admin['id'],$action,$previousStatus,$previousExpires,$nextStatus,$nextExpires,$reason]);
                audit('adjust_membership',(int)$id,$action.' → '.$nextExpires.' · '.$reason); $db->commit();
                flash($operation==='grant'?'会员权益已调整。':'人工赠送权益已撤销；有效商店订阅继续保留。'); redirect('user','&id='.(int)$id);
            }
            if ($action==='retry_ai') {
                $id=strtolower(trim((string)($_POST['job_id']??'')));
                if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D',$id)) throw new RuntimeException('任务编号无效。');
                aiAdmin('/v1/jobs/'.$id.'/retry','POST');
                audit('retry_ai',null,'任务 '.substr($id,0,8));
                flash('已请求重新执行 AI 任务。'); redirect('ai');
            }
            if ($action==='ai_control') {
                $target=(string)($_POST['accepting']??''); $reason=trim((string)($_POST['reason']??''));
                if(!in_array($target,['on','off'],true)||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的操作原因。');
                $enabled=aiAdmin('/v1/admin/ai/settings','POST',['accepting'=>$target==='on'])['accepting']??null;
                if(!is_bool($enabled)) throw new RuntimeException('AI 服务状态更新未确认。');
                audit($enabled?'enable_ai':'pause_ai',null,$reason);
                flash($enabled?'AI 已恢复接收新任务。':'AI 已暂停接收新任务，队列中任务会继续完成。'); redirect('ai');
            }
            if ($action==='ai_capacity') {
                $daily=filter_var($_POST['daily_limit']??null,FILTER_VALIDATE_INT);
                $accountDaily=filter_var($_POST['account_daily_limit']??null,FILTER_VALIDATE_INT);
                $pending=filter_var($_POST['pending_limit']??null,FILTER_VALIDATE_INT);
                $accountPending=filter_var($_POST['account_pending_limit']??null,FILTER_VALIDATE_INT);
                $workers=filter_var($_POST['worker_limit']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if($accountDaily===false||$accountDaily<0||$accountDaily>2147483647||$pending===false||$accountPending===false||$daily===false||$workers===false||$daily<0||$pending<0||$accountPending<0||$daily>2147483647||$pending>2147483647||$accountPending>2147483647||$workers<1||$workers>32||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('容量填写 0—2147483647，并发填写 1—32，并说明操作原因。');
                $before=aiAdmin('/v1/admin/ai/settings');
                $saved=aiAdmin('/v1/admin/ai/settings','POST',['daily_limit'=>$daily,'account_daily_limit'=>$accountDaily,'account_pending_limit'=>$accountPending,'pending_limit'=>$pending,'worker_limit'=>$workers]);
                if(($saved['account_daily_limit']??null)!==$accountDaily||($saved['account_pending_limit']??null)!==$accountPending||($saved['daily_limit']??null)!==$daily||($saved['pending_limit']??null)!==$pending||($saved['worker_limit']??null)!==$workers) throw new RuntimeException('容量设置未确认，请刷新后核对。');
                audit('update_ai_capacity',null,'每账号每日 '.($before['account_daily_limit']??'?').' → '.$accountDaily.'；单账号未结束 '.($before['account_pending_limit']??'?').' → '.$accountPending.'；全服务每日 '.($before['daily_limit']??'?').' → '.$daily.'；未结束 '.($before['pending_limit']??'?').' → '.$pending.'；并发 '.($before['worker_limit']??'?').' → '.$workers.' · '.$reason);
                flash('AI 容量已保存，并发约 1 秒内应用；服务重启后仍保留。'); redirect('ai');
            }
            if($action==='storage_capacity') {
                $mib=filter_var($_POST['storage_limit_mib']??null,FILTER_VALIDATE_INT);
                $files=filter_var($_POST['media_file_limit']??null,FILTER_VALIDATE_INT);
                $rate=filter_var($_POST['media_uploads_per_minute']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if($mib===false||$files===false||$rate===false||$mib<0||$files<0||$rate<1||max($mib,$files,$rate)>2147483647||mb_strlen($reason)<2||mb_strlen($reason)>200)throw new RuntimeException('照片空间/数量填0或正整数，上传保护填正整数，并填写操作原因。');
                $db->beginTransaction();
                foreach(['media_storage_limit_bytes'=>$mib*1048576,'media_file_limit'=>$files,'media_uploads_per_minute'=>$rate] as $key=>$value)query('INSERT INTO storage_settings(setting_key,setting_value,updated_at) VALUES(?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value),updated_at=VALUES(updated_at)',[$key,$value]);
                audit('update_storage_capacity',null,'每账号照片空间MB='.$mib.'；文件数='.$files.'；分钟上传保护='.$rate.' · '.$reason);
                $db->commit();flash('照片设置已保存，已存照片保留。');redirect('storage');
            }
            if ($action==='ai_router_update') {
                $password=(string)($_POST['current_password']??'');$reason=trim((string)($_POST['reason']??''));
                $row=query('SELECT password_hash FROM admin_accounts WHERE id=?',[$admin['id']])->fetch();
                if(!$row||!password_verify($password,$row['password_hash'])||mb_strlen($reason)<2||mb_strlen($reason)>200)throw new RuntimeException('请核对当前密码和操作原因。');
                $weights=[];foreach(['chat','reference','proposal','complex','vision'] as $bucket){$v=filter_var($_POST['weight_'.$bucket]??null,FILTER_VALIDATE_INT);if($v===false||$v<10||$v>90)throw new RuntimeException('DeepSeek比例应为10至90。');$weights[$bucket]=$v/100;}
                aiAdmin('/v1/admin/ai/router','POST',['enabled'=>isset($_POST['enabled']),'weights'=>$weights]);
                audit('update_ai_router',null,json_encode($weights).' · '.$reason);flash('路由分配已保存；能力、授权与熔断优先。');redirect('ai');
            }
            if ($action==='ai_provider_update') {
                $name=(string)($_POST['provider']??''); $priority=filter_var($_POST['priority']??null,FILTER_VALIDATE_INT);
                $enabled=(string)($_POST['enabled']??'')==='1'; $key=trim((string)($_POST['api_key']??''));
                $clearKey=(string)($_POST['clear_key']??'')==='1';
                $password=(string)($_POST['current_password']??''); $reason=trim((string)($_POST['reason']??''));
                if(!in_array($name,['deepseek','minimax'],true)||!$priority||$priority<1||$priority>99||strlen($key)>500||str_contains($key,"\n")||str_contains($key,"\r")||($clearKey&&$key!=='')||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('接口配置或操作原因不正确。');
                $row=query('SELECT password_hash FROM admin_accounts WHERE id=?',[$admin['id']])->fetch();
                if(!$row||!password_verify($password,$row['password_hash'])) throw new RuntimeException('当前管理员密码不正确，未修改接口配置。');
                aiAdmin('/v1/admin/ai/providers','POST',['name'=>$name,'enabled'=>$enabled,'priority'=>$priority,'key'=>$key,'clear_key'=>$clearKey]);
                audit('update_ai_provider',null,$name.' · '.($enabled?'启用':'停用').' · 优先级 '.$priority.($clearKey?' · 已清除密钥':'').' · '.$reason);
                flash('AI 接口配置已更新；密钥不会在后台显示。'); redirect('ai');
            }
            if ($action==='member_tags') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $submitted=$_POST['tags']??[];
                if(!$id||!is_array($submitted)||count($submitted)>count(memberTagOptions())) throw new RuntimeException('成员标签不正确。');
                $tags=array_values(array_unique(array_map('strval',$submitted)));
                if(array_diff($tags,memberTagOptions())) throw new RuntimeException('成员标签不正确。');
                if(!query('SELECT 1 FROM users WHERE id=?',[$id])->fetchColumn()) throw new RuntimeException('成员不存在。');
                query('INSERT INTO member_admin_profiles(user_id,tags_json,updated_by,updated_at) VALUES(?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE tags_json=VALUES(tags_json),updated_by=VALUES(updated_by),updated_at=VALUES(updated_at)',[$id,json_encode($tags,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),$admin['id']]);
                audit('update_member_tags',(int)$id,implode('、',$tags));
                flash('成员标签已更新。'); redirect('user','&id='.(int)$id);
            }
            if ($action==='member_note') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $note=trim((string)($_POST['note']??''));
                if(!$id||mb_strlen($note)<2||mb_strlen($note)>1000) throw new RuntimeException('备注需为 2—1000 字。');
                if(!query('SELECT 1 FROM users WHERE id=?',[$id])->fetchColumn()) throw new RuntimeException('成员不存在。');
                query('INSERT INTO member_admin_notes(user_id,admin_id,note,created_at) VALUES(?,?,?,UTC_TIMESTAMP())',[$id,$admin['id'],$note]);
                audit('add_member_note',(int)$id,'新增运营备注');
                flash('运营备注已保存。'); redirect('user','&id='.(int)$id);
            }
            if ($action==='notification_template_create' || $action==='notification_template_update') {
                $id=$action==='notification_template_update'?filter_var($_POST['id']??null,FILTER_VALIDATE_INT):0;
                $category=(string)($_POST['category']??'system');$name=mb_substr(trim((string)($_POST['name']??'')),0,80);
                $title=mb_substr(trim((string)($_POST['title']??'')),0,120);$body=mb_substr(trim((string)($_POST['body']??'')),0,300);
                $oldTemplate=$id?query('SELECT deeplink,default_enabled,sound,badge FROM notification_templates WHERE id=?',[$id])->fetch():null;
                $deeplink=isset($_POST['deeplink'])?mb_substr(trim((string)$_POST['deeplink']),0,160):(string)($oldTemplate['deeplink']??'');
                $enabled=isset($_POST['enabled'])?1:0;$defaultEnabled=isset($_POST['default_enabled'])?1:(int)($oldTemplate['default_enabled']??0);$sound=isset($_POST['sound'])?1:(isset($_POST['delivery_flags_present'])?0:($oldTemplate['sound']??0));$badge=isset($_POST['badge'])?1:(isset($_POST['delivery_flags_present'])?0:($oldTemplate['badge']??0));
                $categories=['training','daily_report','weekly_review','reward','shipping','membership','system'];
                if(!in_array($category,$categories,true)||$name===''||$title===''||$body==='') throw new RuntimeException('通知模板资料不完整。');
                if($action==='notification_template_create'){
                    if(query('SELECT 1 FROM notification_templates WHERE name=?',[$name])->fetchColumn()) throw new RuntimeException('通知模板名称已存在。');
                    query('INSERT INTO notification_templates(category,name,title,body,deeplink,enabled,default_enabled,sound,badge,active,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())',[$category,$name,$title,$body,$deeplink,$enabled,$defaultEnabled,$sound,$badge]);
                }else{
                    if(!$id||!query('SELECT 1 FROM notification_templates WHERE id=?',[$id])->fetchColumn()) throw new RuntimeException('通知模板不存在。');
                    query('UPDATE notification_templates SET category=?,name=?,title=?,body=?,deeplink=?,enabled=?,default_enabled=?,sound=?,badge=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$category,$name,$title,$body,$deeplink,$enabled,$defaultEnabled,$sound,$badge,$id]);
                }
                audit($action,null,'通知模板 '.$name);flash('通知模板已保存。');redirect('notifications');
            }
            if ($action==='notification_template_archive') {
                $id=filter_var($_POST['id']??null,FILTER_VALIDATE_INT);
                if(!$id) throw new RuntimeException('通知模板不存在。');
                query('UPDATE notification_templates SET active=0,updated_at=UTC_TIMESTAMP() WHERE id=?',[$id]);
                audit('archive_notification_template',null,'通知模板 '.$id);flash('通知模板已归档。');redirect('notifications');
            }
            if ($action==='notification_plan_create' || $action==='notification_plan_update') {
                $planId=scheduleAdminSave($db,$_POST,(int)$admin['id'],$action==='notification_plan_update');
                audit($action,null,'通知计划 '.$planId);flash('草稿已保存，核对接收范围后再启用。');redirect('notifications','&tab=plans&plan='.$planId);
            }
            if(in_array($action,['notification_plan_publish','notification_plan_pause'],true)){
                scheduleAdminSetState($db,$_POST,$config,(int)$admin['id'],$action==='notification_plan_publish');
                audit($action,null,'通知计划 '.(int)$_POST['id']);flash($action==='notification_plan_publish'?'计划已启用，将从下一个发送时间开始。':'计划已暂停。');redirect('notifications','&tab=plans&plan='.(int)$_POST['id']);
            }
            if ($action==='notification_test') {
                $templateId=filter_var($_POST['template_id']??null,FILTER_VALIDATE_INT);
                $userId=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $template=$templateId?query('SELECT * FROM notification_templates WHERE id=? AND active=1',[$templateId])->fetch():null;
                if(!$template) throw new RuntimeException('通知模板不存在。');
                if(empty($template['enabled'])) throw new RuntimeException('该模板已停用，启用后才能发送测试通知。');
                if(!$userId) throw new RuntimeException('请指定一名接收测试通知的成员。');
                $device=$userId?query('SELECT * FROM club_push_devices WHERE user_id=? AND enabled=1 ORDER BY updated_at DESC LIMIT 1',[$userId])->fetch():null;
                if(!$device) throw new RuntimeException('该成员没有启用中的推送设备。请让成员先在 App 内开启通知。');
                if(!clubPushConfigured($config)) throw new RuntimeException('APNs 尚未配置，不能发送真实测试通知。配置文件就绪后可重试。');
                if(!clubPushTransportReady()) throw new RuntimeException('当前 PHP 缺少 HTTP/2 cURL，不能发送 APNs。');
                $payload=['aps'=>['alert'=>['title'=>$template['title'],'body'=>$template['body']],'thread-id'=>'boji-admin-test'],
                    'boji_kind'=>'system','boji_date'=>date('Y-m-d'),'boji_account'=>$userId,'boji_deeplink'=>$template['deeplink']??''];
                if(!empty($template['sound'])) $payload['aps']['sound']='default';
                if(!empty($template['badge'])) $payload['aps']['badge']=1;
                $result=clubPushSendContent($config,$device,$payload,hash('sha256','admin-test/'.$device['device_id'].'/'.$templateId.'/'.time()));
                $sent=($result['status']??0)===200;
                query('INSERT INTO notification_deliveries(template_id,user_id,category,title,body,status,provider,error,created_at) VALUES(?,?,?,?,?,?,?,?,UTC_TIMESTAMP())',[$templateId,$userId,$template['category'],$template['title'],$template['body'],$sent?'sent':'failed','admin_test',$sent?'':(string)($result['reason']??'UnknownError')]);
                audit('test_notification',$userId,$template['name'].' · '.($sent?'sent':'failed '.$result['reason']));
                flash($sent?'测试通知已通过 APNs 发送给 1 名成员。':'APNs 返回失败：'.($result['reason']??'UnknownError').'。已记录发送结果，未向其他成员发送。');
                redirect('notifications');
            }
            if ($action==='automation_pause' || $action==='automation_resume' || $action==='automation_rerun') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if(!$id||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的操作原因。');
                if(!query('SELECT 1 FROM club_automation WHERE user_id=?',[$id])->fetchColumn()) throw new RuntimeException('该成员尚未配置自动跟进。');
                if($action==='automation_pause') {
                    query('UPDATE club_automation SET paused=1,paused_reason=?,updated_at=UTC_TIMESTAMP() WHERE user_id=?',[$reason,$id]);
                    audit('pause_automation',$id,$reason);
                    flash('自动跟进已暂停调度；用户设置与既有报告保留。');
                } elseif($action==='automation_resume') {
                    query('UPDATE club_automation SET paused=0,paused_reason=NULL,updated_at=UTC_TIMESTAMP() WHERE user_id=?',[$id]);
                    audit('resume_automation',$id,$reason);
                    flash('自动跟进已恢复调度。');
                } else {
                    // 手动重跑：清零重试计数并立即调度，是终态 failed 的恢复路径之一（另一条是用户再次保存配置）。
                    query("UPDATE club_automation SET retry_count=0,next_run=UTC_TIMESTAMP(),last_status='retry_reset',paused=0,paused_reason=NULL,updated_at=UTC_TIMESTAMP() WHERE user_id=?",[$id]);
                    audit('rerun_automation',$id,$reason);
                    flash('已清零重试计数并立即调度自动跟进。');
                }
                redirect('automation');
            }
            if ($action==='push_budget_update') {
                $limit=filter_var($_POST['proactive_daily_limit']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if($limit===false||$limit<0||$limit>20||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('普通主动推送每日上限填写 0—20，并说明操作原因。');
                $before=query("SELECT setting_value FROM club_push_settings WHERE setting_key='proactive_daily_limit'")->fetchColumn();
                query("INSERT INTO club_push_settings(setting_key,setting_value,updated_at) VALUES('proactive_daily_limit',?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value),updated_at=UTC_TIMESTAMP()",[$limit]);
                audit('update_push_budget',null,'每日上限 '.($before===false?'默认':(string)$before).' → '.$limit.' · '.$reason);
                flash('普通主动推送预算已保存，下次发送预约时生效。');
                redirect('push');
            }
            if ($action==='push_block' || $action==='push_unblock') {
                $id=filter_var($_POST['user_id']??null,FILTER_VALIDATE_INT);
                $reason=trim((string)($_POST['reason']??''));
                if(!$id||mb_strlen($reason)<2||mb_strlen($reason)>200) throw new RuntimeException('请填写 2—200 字的操作原因。');
                if(!query('SELECT 1 FROM users WHERE id=? AND status<>"deleted"',[$id])->fetchColumn()) throw new RuntimeException('成员不存在或已注销。');
                if($action==='push_block') {
                    query('INSERT INTO club_push_account_blocks(user_id,reason,blocked_by,created_at,updated_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE reason=VALUES(reason),blocked_by=VALUES(blocked_by),updated_at=UTC_TIMESTAMP()',[$id,$reason,(int)$admin['id']]);
                    audit('block_push',$id,$reason);
                    flash('已停发该账号的推送；设备与历史回执保留。');
                } else {
                    query('DELETE FROM club_push_account_blocks WHERE user_id=?',[$id]);
                    audit('unblock_push',$id,$reason);
                    flash('已恢复该账号的推送调度。');
                }
                redirect('push');
            }
            if ($action==='club_season_create') {
                $title=mb_substr(trim((string)($_POST['title']??'')),0,80);
                $subtitle=mb_substr(trim((string)($_POST['subtitle']??'')),0,160);
                $note=mb_substr(trim((string)($_POST['official_note']??'')),0,3000);
                $rules=mb_substr(trim((string)($_POST['rules_text']??'')),0,5000);
                $starts=(string)($_POST['starts_on']??''); $ends=(string)($_POST['ends_on']??'');
                $deadline=(string)($_POST['join_deadline']??''); $capacity=(int)($_POST['capacity']??0);
                foreach([$starts,$ends,$deadline] as $date) if(!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$date)) throw new RuntimeException('活动日期不正确。');
                if($title===''||$subtitle===''||mb_strlen($note)<10||mb_strlen($rules)<10||$ends<$starts||$deadline<$starts||$deadline>$ends||$capacity<1||$capacity>100000) throw new RuntimeException('请完整填写活动信息，检查日期和名额。');
                $taskTitles=is_array($_POST['task_title']??null)?$_POST['task_title']:[];
                $taskDetails=is_array($_POST['task_detail']??null)?$_POST['task_detail']:[];
                $taskMetrics=is_array($_POST['task_metric']??null)?$_POST['task_metric']:[];
                $taskTargets=is_array($_POST['task_target']??null)?$_POST['task_target']:[];
                $taskCatalogIds=is_array($_POST['task_catalog_id']??null)?$_POST['task_catalog_id']:[];
                if(count($taskTitles)<1||count($taskTitles)>12) throw new RuntimeException('请至少设置一条任务，最多设置十二条。');
                if(count($taskDetails)!==count($taskTitles)||count($taskMetrics)!==count($taskTitles)||count($taskTargets)!==count($taskTitles)||count($taskCatalogIds)!==count($taskTitles)) throw new RuntimeException('任务资料不完整。');
                $metrics=['training_days','meal_days','weekly_reviews','meal_records','daily_reports','health_days'];
                $db->beginTransaction();
                $slug=$starts.'-'.bin2hex(random_bytes(3));
                query("INSERT INTO club_seasons(slug,title,subtitle,official_note,rules_text,starts_on,ends_on,join_deadline,status,access_mode,capacity,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,'draft','included',?,UTC_TIMESTAMP(),UTC_TIMESTAMP())",[$slug,$title,$subtitle,$note,$rules,$starts,$ends,$deadline,$capacity]);
                $seasonId=(int)$db->lastInsertId();
                foreach($taskTitles as $index=>$rawTitle){
                    $taskTitle=mb_substr(trim((string)$rawTitle),0,80);
                    $taskDetail=mb_substr(trim((string)($taskDetails[$index]??'')),0,200);
                    $metric=(string)($taskMetrics[$index]??'');
                    $target=(int)($taskTargets[$index]??0);
                    $catalogId=filter_var($taskCatalogIds[$index]??null,FILTER_VALIDATE_INT);
                    $catalog=$catalogId?query('SELECT * FROM club_reward_catalog WHERE id=? AND active=1',[$catalogId])->fetch():null;
                    if($taskTitle===''||$taskDetail===''||!in_array($metric,$metrics,true)||$target<1||$target>31||!$catalog){$db->rollBack();throw new RuntimeException('任务或对应奖励资料不正确。');}
                    query('INSERT INTO club_tasks(season_id,title,detail,metric,target,sort_order,created_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())',[$seasonId,$taskTitle,$taskDetail,$metric,$target,($index+1)*10]);
                    $taskId=(int)$db->lastInsertId();
                    query('INSERT INTO club_rewards(season_id,task_id,catalog_id,title,detail,reward_type,icon,image_path,sku,inventory,max_per_user,claim_deadline,sort_order,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())',[$seasonId,$taskId,$catalogId,$catalog['name'],$catalog['detail'],$catalog['kind'],$catalog['icon'],$catalog['image_path'],$catalog['sku'],$catalog['default_inventory'],$catalog['max_per_user'],$catalog['claim_deadline'],($index+1)*10]);
                }
                audit('create_club_season',null,'成长季 '.$seasonId.' '.$title.'，自定义任务 '.count($taskTitles).' 条');$db->commit();
                flash('成长季草稿已创建，任务和奖励已按你的配置写入。');redirect('club','&season='.$seasonId);
            }
            if ($action==='club_season_update' && isset($_POST['task_delete_id'])) {
                $taskId=filter_var($_POST['task_delete_id'],FILTER_VALIDATE_INT);
                $task=$taskId?query('SELECT t.*,s.status FROM club_tasks t JOIN club_seasons s ON s.id=t.season_id WHERE t.id=?',[$taskId])->fetch():null;
                if(!$task||$task['status']!=='draft') throw new RuntimeException('只能删除未发布的成长季任务。');
                $db->beginTransaction();query('DELETE FROM club_rewards WHERE task_id=?',[$taskId]);query('DELETE FROM club_tasks WHERE id=?',[$taskId]);$db->commit();
                audit('delete_club_task',null,'成长季 '.$task['season_id'].' 任务 '.$taskId.' '.$task['title']);flash('任务已删除。');redirect('club','&season='.(int)$task['season_id']);
            }
            if ($action==='club_season_update') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $season=$seasonId?query('SELECT * FROM club_seasons WHERE id=?',[$seasonId])->fetch():null;
                if(!$season||$season['status']!=='draft') throw new RuntimeException('只有草稿可以修改，已发布规则会为参与者锁定。');
                $title=mb_substr(trim((string)($_POST['title']??'')),0,80); $subtitle=mb_substr(trim((string)($_POST['subtitle']??'')),0,160);
                $note=mb_substr(trim((string)($_POST['official_note']??'')),0,3000); $rules=mb_substr(trim((string)($_POST['rules_text']??'')),0,5000);
                $starts=(string)($_POST['starts_on']??'');$ends=(string)($_POST['ends_on']??'');$deadline=(string)($_POST['join_deadline']??'');$capacity=(int)($_POST['capacity']??0);
                if($title===''||$subtitle===''||mb_strlen($note)<10||mb_strlen($rules)<10||!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$starts)||$ends<$starts||$deadline<$starts||$deadline>$ends||$capacity<1) throw new RuntimeException('活动资料不完整。');
                $db->beginTransaction();
                query('UPDATE club_seasons SET title=?,subtitle=?,official_note=?,rules_text=?,starts_on=?,ends_on=?,join_deadline=?,capacity=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$title,$subtitle,$note,$rules,$starts,$ends,$deadline,$capacity,$seasonId]);
                foreach(query('SELECT id,metric FROM club_tasks WHERE season_id=?',[$seasonId])->fetchAll() as $task){$id=(int)$task['id'];$taskTitle=mb_substr(trim((string)($_POST['task_title'][$id]??'')),0,80);$detail=mb_substr(trim((string)($_POST['task_detail'][$id]??'')),0,200);$target=(int)($_POST['task_target'][$id]??0);$metric=(string)($_POST['task_metric'][$id]??$task['metric']);$metrics=['training_days','meal_days','weekly_reviews','meal_records','daily_reports','health_days'];if($taskTitle===''||$detail===''||$target<1||$target>31||!in_array($metric,$metrics,true)){$db->rollBack();throw new RuntimeException('任务名称、说明、目标值或统计方式不正确。');}query('UPDATE club_tasks SET title=?,detail=?,target=?,metric=? WHERE id=?',[$taskTitle,$detail,$target,$metric,$id]);}
                foreach(query('SELECT id,reward_type,icon,catalog_id FROM club_rewards WHERE season_id=?',[$seasonId])->fetchAll() as $reward){
                    $id=(int)$reward['id'];
                    $rewardTitle=mb_substr(trim((string)($_POST['reward_title'][$id]??'')),0,80);
                    $detail=mb_substr(trim((string)($_POST['reward_detail'][$id]??'')),0,200);
                    $rewardType=(string)($_POST['reward_type'][$id]??$reward['reward_type']);
                    $icon=(string)($_POST['reward_icon'][$id]??$reward['icon']);
                    $sku=mb_substr(trim((string)($_POST['reward_sku'][$id]??'')),0,80);
                    $catalogValue=$_POST['reward_catalog_id'][$id]??'';
                    $catalogId=$catalogValue===''?null:filter_var($catalogValue,FILTER_VALIDATE_INT);
                    if($catalogId===false || ($catalogId!==null && $catalogId<1)) throw new RuntimeException('所选徽章/礼品编号不正确。');
                    $maxPerUser=1;
                    $claimDeadline=trim((string)($_POST['reward_claim_deadline'][$id]??''));
                    $inventory=$rewardType==='physical'?(int)($_POST['reward_inventory'][$id]??0):null;
                    $allowedTypes=['badge','title','physical'];
                    $allowedIcons=['seal','sparkles','leaf','gift'];
                    $file = [
                        'error' => $_FILES['reward_image']['error'][$id] ?? UPLOAD_ERR_NO_FILE,
                        'size' => $_FILES['reward_image']['size'][$id] ?? 0,
                        'tmp_name' => $_FILES['reward_image']['tmp_name'][$id] ?? '',
                    ];
                    $catalogImage=null;
                    $catalogChanged=$catalogId && $catalogId!==(int)$reward['catalog_id'];
                    if($catalogId && $catalogId!==(int)$reward['catalog_id']){
                        $catalog=query('SELECT * FROM club_reward_catalog WHERE id=? AND active=1',[$catalogId])->fetch();
                        if(!$catalog){$db->rollBack();throw new RuntimeException('所选徽章/礼品不存在。');}
                        $catalogImage=$catalog['image_path'];
                        $rewardTitle=(string)$catalog['name'];$detail=(string)$catalog['detail'];$rewardType=(string)$catalog['kind'];$icon=(string)$catalog['icon'];$sku=(string)($catalog['sku']??'');$inventory=$rewardType==='physical'?(int)($catalog['default_inventory']??0):null;$maxPerUser=1;$claimDeadline=(string)($catalog['claim_deadline']??'');
                    }
                    if($rewardTitle===''||$detail===''||!in_array($rewardType,$allowedTypes,true)||!in_array($icon,$allowedIcons,true)||($rewardType==='physical'&&$inventory<1)||$maxPerUser<1||$maxPerUser>10||($claimDeadline!==''&&!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$claimDeadline))){
                        $db->rollBack();throw new RuntimeException('奖励资料、类型、库存或申领期限不正确。');
                    }
                    $imagePath=saveRewardImage($seasonId,$id,$file) ?? $catalogImage;
                    $sql='UPDATE club_rewards SET title=?,detail=?,reward_type=?,icon=?,sku=?,inventory=?,max_per_user=?,claim_deadline=?,catalog_id=?';
                    $params=[$rewardTitle,$detail,$rewardType,$icon,$sku,$inventory,$maxPerUser,$claimDeadline===''?null:$claimDeadline,$catalogId];
                    if($imagePath!==null || $catalogChanged){$sql.=',image_path=?';$params[]=$imagePath;}
                    $sql.=' WHERE id=?';$params[]=$id;
                    query($sql,$params);
                }
                audit('update_club_season',null,'成长季 '.$seasonId);$db->commit();flash('成长季草稿已保存。');redirect('club','&season='.$seasonId);
            }
            if ($action==='reward_catalog_create' || $action==='reward_catalog_update') {
                $id = $action==='reward_catalog_update' ? filter_var($_POST['id']??null,FILTER_VALIDATE_INT) : 0;
                $kind=(string)($_POST['kind']??'badge');
                $name=mb_substr(trim((string)($_POST['name']??'')),0,80);
                $detail=mb_substr(trim((string)($_POST['detail']??'')),0,200);
                $icon=(string)($_POST['icon']??'seal');
                $sku=mb_substr(trim((string)($_POST['sku']??'')),0,80);
                $inventory=(int)($_POST['default_inventory']??0);
                $maxPerUser=1;
                $deadline=trim((string)($_POST['claim_deadline']??''));
                $active=isset($_POST['active'])?1:0;
                if(!in_array($kind,['badge','title','physical'],true)||$name===''||!in_array($icon,['seal','sparkles','leaf','gift'],true)||$maxPerUser<1||$maxPerUser>10||($deadline!==''&&!preg_match('/^\d{4}-\d{2}-\d{2}$/D',$deadline))) throw new RuntimeException('徽章/礼品资料不正确。');
                if($kind==='physical' && $inventory<1) throw new RuntimeException('实物礼品库存至少为 1。');
                $db->beginTransaction();
                if($action==='reward_catalog_create'){
                    query('INSERT INTO club_reward_catalog(kind,name,detail,icon,sku,default_inventory,max_per_user,claim_deadline,active,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())',[$kind,$name,$detail,$icon,$sku,$kind==='physical'?$inventory:null,$maxPerUser,$deadline===''?null:$deadline,$active]);
                    $id=(int)$db->lastInsertId();
                } else {
                    if(!$id||!query('SELECT 1 FROM club_reward_catalog WHERE id=?',[$id])->fetchColumn()) throw new RuntimeException('徽章/礼品不存在。');
                    query('UPDATE club_reward_catalog SET kind=?,name=?,detail=?,icon=?,sku=?,default_inventory=?,max_per_user=?,claim_deadline=?,active=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$kind,$name,$detail,$icon,$sku,$kind==='physical'?$inventory:null,$maxPerUser,$deadline===''?null:$deadline,$active,$id]);
                }
                $catalogImagePath=saveCatalogImage($id,$_FILES['image']??['error'=>UPLOAD_ERR_NO_FILE]);
                if($catalogImagePath!==null) query('UPDATE club_reward_catalog SET image_path=? WHERE id=?',[$catalogImagePath,$id]);
                audit($action,null,'奖励库 '.$id.' '.$name);$db->commit();flash('徽章/礼品库已保存。');redirect($kind==='physical'?'gifts':'badges');
            }
            if ($action==='reward_catalog_archive') {
                $id=filter_var($_POST['id']??null,FILTER_VALIDATE_INT);
                if(!$id) throw new RuntimeException('奖励不存在。');
                $archivedKind=(string)query('SELECT kind FROM club_reward_catalog WHERE id=?',[$id])->fetchColumn();
                if($archivedKind==='') throw new RuntimeException('奖励不存在。');
                query('UPDATE club_reward_catalog SET active=0,updated_at=UTC_TIMESTAMP() WHERE id=?',[$id]);
                audit('archive_reward_catalog',null,'奖励库 '.$id);flash('已归档该徽章/礼品。');redirect($archivedKind==='physical'?'gifts':'badges');
            }
            if ($action==='club_task_create') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $title=mb_substr(trim((string)($_POST['title']??'')),0,80);
                $detail=mb_substr(trim((string)($_POST['detail']??'')),0,200);
                $metric=(string)($_POST['metric']??'training_days');
                $target=(int)($_POST['target']??0);
                $catalogId=filter_var($_POST['catalog_id']??null,FILTER_VALIDATE_INT);
                $metrics=['training_days','meal_days','weekly_reviews','meal_records','daily_reports','health_days'];
                $season=$seasonId?query("SELECT * FROM club_seasons WHERE id=? AND status='draft'",[$seasonId])->fetch():null;
                $catalog=$catalogId?query('SELECT * FROM club_reward_catalog WHERE id=? AND active=1',[$catalogId])->fetch():null;
                if(!$season||!$catalog||$title===''||$detail===''||!in_array($metric,$metrics,true)||$target<1||$target>31) throw new RuntimeException('任务或奖励资料不正确。');
                $db->beginTransaction();
                query('INSERT INTO club_tasks(season_id,title,detail,metric,target,sort_order,created_at) VALUES(?,?,?,?,?,(SELECT COALESCE(MAX(sort_order),0)+10 FROM club_tasks WHERE season_id=?),UTC_TIMESTAMP())',[$seasonId,$title,$detail,$metric,$target,$seasonId]);
                $taskId=(int)$db->lastInsertId();
                $taskSort=(int)query('SELECT sort_order FROM club_tasks WHERE id=?',[$taskId])->fetchColumn();
                query('INSERT INTO club_rewards(season_id,task_id,catalog_id,title,detail,reward_type,icon,image_path,sku,inventory,max_per_user,claim_deadline,sort_order,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())',[$seasonId,$taskId,$catalogId,$catalog['name'],$catalog['detail'],$catalog['kind'],$catalog['icon'],$catalog['image_path'],$catalog['sku'],$catalog['default_inventory'],$catalog['max_per_user'],$catalog['claim_deadline'],$taskSort]);
                audit('create_club_task',null,'成长季 '.$seasonId.' 任务 '.$taskId);$db->commit();flash('任务和奖励已添加。');redirect('club','&season='.$seasonId);
            }
            if ($action==='club_season_delete') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $season=$seasonId?query('SELECT * FROM club_seasons WHERE id=?',[$seasonId])->fetch():null;
                if(!$season) throw new RuntimeException('成长季不存在。');
                $joined=(int)query('SELECT COUNT(*) FROM club_enrollments WHERE season_id=?',[$seasonId])->fetchColumn();
                $claims=(int)query('SELECT COUNT(*) FROM club_reward_claims WHERE season_id=?',[$seasonId])->fetchColumn();
                $grants=(int)query('SELECT COUNT(*) FROM club_virtual_grants WHERE season_id=?',[$seasonId])->fetchColumn();
                if($joined||$claims||$grants) throw new RuntimeException('已有成员、奖励或申领记录的成长季不能彻底删除，请先下架并保留历史。');
                $db->beginTransaction();
                query('DELETE FROM club_reward_claims WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_virtual_grants WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_announcements WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_rewards WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_tasks WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_enrollments WHERE season_id=?',[$seasonId]);
                query('DELETE FROM club_seasons WHERE id=?',[$seasonId]);
                $db->commit();
                audit('delete_club_season',null,'成长季 '.$seasonId.' '.$season['title']);
                flash('成长季已彻底删除。');redirect('club');
            }
            if ($action==='club_season_archive') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $season=$seasonId?query('SELECT * FROM club_seasons WHERE id=?',[$seasonId])->fetch():null;
                if(!$season||$season['status']==='archived') throw new RuntimeException('成长季不存在或已下架。');
                query("UPDATE club_seasons SET status='archived',updated_at=UTC_TIMESTAMP() WHERE id=?",[$seasonId]);
                audit('archive_club_season',null,'成长季 '.$seasonId);flash('成长季已下架，历史记录继续保留。');redirect('club');
            }
            if ($action==='club_season_publish') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $db->beginTransaction();
                $season=$seasonId?query("SELECT * FROM club_seasons WHERE id=? AND status='draft' FOR UPDATE",[$seasonId])->fetch():null;
                if(!$season) throw new RuntimeException('成长季不存在或已发布。');
                $date=static function(string $value): bool { $d=DateTimeImmutable::createFromFormat('!Y-m-d',$value);return $d!==false && $d->format('Y-m-d')===$value; };
                if(!$date($season['starts_on']) || !$date($season['ends_on']) || !$date($season['join_deadline']) || $season['ends_on']<$season['starts_on'] || $season['ends_on']<date('Y-m-d') || $season['join_deadline']<$season['starts_on'] || $season['join_deadline']>$season['ends_on']) throw new RuntimeException('活动日期无效、已经结束或报名截止日不在活动期间。');
                $days=(int)(new DateTimeImmutable($season['starts_on']))->diff(new DateTimeImmutable($season['ends_on']))->days+1;
                $tasks=query('SELECT * FROM club_tasks WHERE season_id=?',[$seasonId])->fetchAll();
                $rewards=query('SELECT * FROM club_rewards WHERE season_id=?',[$seasonId])->fetchAll();
                if(!$tasks || !$rewards) throw new RuntimeException('请至少配置一项任务及其奖励后再发布。');
                $physical=0;
                foreach($tasks as $task) {
                    $maximum=in_array($task['metric'],['training_days','meal_days','daily_reports','health_days'],true)?$days:($task['metric']==='weekly_reviews'?(int)ceil($days/7):$days*50);
                    if((int)$task['target']<1 || (int)$task['target']>$maximum) throw new RuntimeException('任务目标超过活动期间可以完成的数量。');
                    if(!array_filter($rewards,static fn($r)=>(int)$r['task_id']===(int)$task['id'])) throw new RuntimeException('每项任务都需要关联奖励。');
                }
                foreach($rewards as $reward) {
                    if(!empty($reward['claim_deadline']) && (!$date($reward['claim_deadline']) || $reward['claim_deadline']<$season['ends_on'])) throw new RuntimeException('礼品申领截止日不能早于活动结束日。');
                    if($reward['reward_type']==='physical') {
                        $physical++;
                        if($reward['inventory']===null || (int)$reward['inventory']<(int)$season['capacity']) throw new RuntimeException('实物库存必须覆盖全部活动名额。');
                    }
                }
                if($physical>1) throw new RuntimeException('每期最多配置一项实物奖励。');
                if(query("SELECT 1 FROM club_seasons WHERE id<>? AND status='published' AND starts_on<=? AND ends_on>=? LIMIT 1 FOR UPDATE",[$seasonId,$season['ends_on'],$season['starts_on']])->fetchColumn()) throw new RuntimeException('活动日期与已发布成长季重叠，请调整日期。');
                query("UPDATE club_seasons SET status='published',updated_at=UTC_TIMESTAMP() WHERE id=?",[$seasonId]);
                audit('publish_club_season',null,'成长季 '.$seasonId);$db->commit();flash('成长季已发布，规则现已锁定。');redirect('club','&season='.$seasonId);
            }
            if ($action==='club_claim_status') {
                $claimId=filter_var($_POST['claim_id']??null,FILTER_VALIDATE_INT);$status=(string)($_POST['status']??'');
                $allowed=['pending','confirmed','packing','shipped','delivered','problem','cancelled'];
                $company=mb_substr(trim((string)($_POST['tracking_company']??'')),0,60);$number=mb_substr(trim((string)($_POST['tracking_number']??'')),0,100);$note=mb_substr(trim((string)($_POST['operator_note']??'')),0,500);
                if(!$claimId||!in_array($status,$allowed,true)||($status==='shipped'&&($company===''||$number===''))) throw new RuntimeException('发货状态或物流信息不完整。');
                $db->beginTransaction();
                $claim=query('SELECT user_id,status,tracking_company,tracking_number,shipped_at,reviewed_at FROM club_reward_claims WHERE id=? FOR UPDATE',[$claimId])->fetch();if(!$claim) throw new RuntimeException('申领记录不存在。');
                $reviewing=($_POST['review_confirmed']??'')==='1';
                if($reviewing && mb_strlen($note)<10) throw new RuntimeException('请记录至少 10 字的人工核验依据。');
                if(in_array($status,['confirmed','packing','shipped','delivered'],true) && empty($claim['reviewed_at']) && !$reviewing) throw new RuntimeException('实物奖励需人工核验，确认依据后才能处理或发货。');
                if($reviewing) {
                    query('UPDATE club_reward_claims SET reviewed_at=UTC_TIMESTAMP(),reviewed_by=? WHERE id=?',[(int)$admin['id'],$claimId]);
                    audit('review_club_claim',(int)$claim['user_id'],'申领 '.$claimId.'：'.$note);
                }
                $transitions=['pending'  =>['confirmed','cancelled','problem'],'confirmed'=>['packing','shipped','cancelled','problem'],'packing'=>['shipped','cancelled','problem'],'shipped'=>['delivered','problem'],'delivered'=>['problem'],'problem'=>['confirmed','packing','shipped','delivered','cancelled'],'cancelled'=>[]];
                if($status!==$claim['status'] && !in_array($status,$transitions[$claim['status']]??[],true)) throw new RuntimeException('不允许将当前履约状态回退；取消的记录须由成员重新申领。');
                if($status==='cancelled' && (!empty($claim['shipped_at']) || !empty($claim['tracking_number']))) throw new RuntimeException('已发货记录不可取消并释放库存。');
                if(!empty($claim['shipped_at'])) {
                    if($company==='') $company=(string)$claim['tracking_company'];
                    if($number==='') $number=(string)$claim['tracking_number'];
                    if(in_array($status,['pending','confirmed','packing'],true)) throw new RuntimeException('已发货记录不能退回未发货状态。');
                }
                query("UPDATE club_reward_claims SET status=?,tracking_company=?,tracking_number=?,operator_note=?,shipped_at=IF(? IN ('shipped','delivered'),COALESCE(shipped_at,UTC_TIMESTAMP()),shipped_at),updated_at=UTC_TIMESTAMP() WHERE id=?",[$status,$company?:null,$number?:null,$note,$status,$claimId]);
                audit('update_club_claim',(int)$claim['user_id'],'申领 '.$claimId.' → '.$status);$db->commit();flash('履约状态已更新。');
                $retPage=(($_POST['return_page']??'')==='shipping' && adminCanViewPage('shipping'))?'shipping':'club';
                redirect($retPage,'&claim='.$claimId);
            }
            if ($action==='club_announcement') {
                $seasonId=filter_var($_POST['season_id']??null,FILTER_VALIDATE_INT);
                $title=mb_substr(trim((string)($_POST['title']??'')),0,100);
                $body=mb_substr(trim((string)($_POST['body']??'')),0,3000);
                if(!$seasonId||$title===''||mb_strlen($body)<5||!query('SELECT 1 FROM club_seasons WHERE id=?',[$seasonId])->fetchColumn()) throw new RuntimeException('请选择成长季并填写完整的官方动态。');
                query('INSERT INTO club_announcements(season_id,title,body,published_at,created_at) VALUES(?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())',[$seasonId,$title,$body]);
                audit('publish_club_announcement',null,'成长季 '.$seasonId.' '.$title);
                flash('官方动态已发布。');redirect('club','&season='.$seasonId);
            }
            if ($action==='config_save_draft') {
                $db->beginTransaction();
                $state=appConfigLockedState($db);
                $expected=filter_var($_POST['draft_version']??null,FILTER_VALIDATE_INT);
                if($expected===false||$expected!==$state['draft_version']) throw new RuntimeException('配置已在其他窗口修改，请刷新后重新核对。');
                $note=trim((string)($_POST['note']??''));
                if(mb_strlen($note)>300) throw new RuntimeException('变更说明最多 300 字。');
                if(isset($_POST['config_section'])) {
                    $config=appConfigDraftMerge($state['draft'],adminConfigSectionChanges($_POST,$state['draft']));
                } else {
                $minimumBuild=filter_var($_POST['minimum_build']??null,FILTER_VALIDATE_INT);
                $latestBuild=filter_var($_POST['latest_build']??null,FILTER_VALIDATE_INT);
                if($minimumBuild===false||$latestBuild===false||$minimumBuild<0||$latestBuild<0) throw new RuntimeException('构建号必须是 0 或正整数。');
                $assistLimit=filter_var($_POST['onboarding_assist_daily_limit']??10,FILTER_VALIDATE_INT);
                $contentVersion=filter_var($_POST['onboarding_content_version']??1,FILTER_VALIDATE_INT);
                if($assistLimit===false||$assistLimit<1||$assistLimit>100) throw new RuntimeException('引导 AI 每日预算必须是 1—100 的整数。');
                if($contentVersion===false||$contentVersion<1||$contentVersion>1000000) throw new RuntimeException('引导内容版本不正确。');
                $advancedPresent=isset($_POST['advanced_ai_flags_present']);
                $config=appConfigDraftMerge($state['draft'],[
                    'ai_enabled'=>isset($_POST['ai_enabled']),
                    'action_system_enabled'=>isset($_POST['action_system_enabled']),
                    'ai_context_references_v1'=>$advancedPresent?isset($_POST['ai_context_references_v1']):(bool)($state['draft']['ai_context_references_v1']??true),
                    'ai_fast_intent_v1'=>$advancedPresent?isset($_POST['ai_fast_intent_v1']):(bool)($state['draft']['ai_fast_intent_v1']??true),
                    'ai_router_v3'=>$advancedPresent?isset($_POST['ai_router_v3']):(bool)($state['draft']['ai_router_v3']??true),
                    'ai_streaming_v2'=>$advancedPresent?isset($_POST['ai_streaming_v2']):(bool)($state['draft']['ai_streaming_v2']??false),
                    'club_enabled'=>isset($_POST['club_enabled']),
                    'ai_native_home'=>isset($_POST['ai_native_home']),
                    'training_commands'=>isset($_POST['training_commands']),
                    'direct_records'=>isset($_POST['direct_records']),
                    'minimum_build'=>$minimumBuild,
                    'latest_build'=>$latestBuild,
                    'announcement'=>['enabled'=>isset($_POST['announcement_enabled']),'title'=>(string)($_POST['announcement_title']??''),'body'=>(string)($_POST['announcement_body']??'')],
                    'onboarding_v2_enabled'=>isset($_POST['onboarding_v2_enabled']),
                    'onboarding_assist_daily_limit'=>$assistLimit,
                    'contextual_tips_enabled'=>isset($_POST['contextual_tips_enabled']),
                    'onboarding_content_version'=>$contentVersion,
                    'onboarding_content'=>[
                        'welcome_title'=>(string)($_POST['onboarding_welcome_title']??''),
                        'welcome_body'=>(string)($_POST['onboarding_welcome_body']??''),
                        'task_labels'=>[
                            'plan_create'=>(string)($_POST['onboarding_task_plan_create']??''),
                            'plan_import'=>(string)($_POST['onboarding_task_plan_import']??''),
                            'meal_log'=>(string)($_POST['onboarding_task_meal_log']??''),
                            'workout_log'=>(string)($_POST['onboarding_task_workout_log']??''),
                            'explore'=>(string)($_POST['onboarding_task_explore']??''),
                        ],
                        'tips'=>is_array($_POST['onboarding_tips']??null)?$_POST['onboarding_tips']:[],
                    ],
                ]);
                }
                $newVersion=$state['draft_version']+1;
                $json=json_encode($config,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
                query("INSERT INTO app_config(config_key,draft_json,draft_version,updated_by,updated_at) VALUES('app',?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE draft_json=VALUES(draft_json),draft_version=VALUES(draft_version),updated_by=VALUES(updated_by),updated_at=UTC_TIMESTAMP()",[$json,$newVersion,(int)$admin['id']]);
                query('INSERT INTO app_config_versions(config_key,version,value_json,action,admin_id,note,created_at) VALUES("app",?,?,"draft",?,?,UTC_TIMESTAMP())',[$newVersion,$json,(int)$admin['id'],$note]);
                audit('update_app_config',null,'草稿 v'.$newVersion.($note!==''?' · '.$note:''));
                $db->commit();flash('草稿已保存。发布后才会下发到 App；当前线上版本未改变。');redirect('config');
            }
            if ($action==='config_publish') {
                $db->beginTransaction();
                $state=appConfigLockedState($db);
                $expected=filter_var($_POST['draft_version']??null,FILTER_VALIDATE_INT);
                if($expected===false||$expected!==$state['draft_version']) throw new RuntimeException('配置已在其他窗口修改，请刷新后重新核对。');
                if($state['draft']===$state['published']) throw new RuntimeException('草稿与已发布版本相同，无需发布。');
                $newVersion=$state['published_version']+1;
                $json=json_encode($state['draft'],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
                $updated=query("UPDATE app_config SET published_json=?,published_version=?,published_at=UTC_TIMESTAMP(),updated_by=?,updated_at=UTC_TIMESTAMP() WHERE config_key='app'",[$json,$newVersion,(int)$admin['id']]);
                if($updated->rowCount()<1){$db->rollBack();throw new RuntimeException('配置发布失败，请刷新后重试。');}
                query('INSERT INTO app_config_versions(config_key,version,value_json,action,admin_id,note,created_at) VALUES("app",?,?,"publish",?,?,UTC_TIMESTAMP())',[$newVersion,$json,(int)$admin['id'],'发布草稿 v'.$state['draft_version']]);
                audit('publish_app_config',null,'发布 v'.$newVersion.'（草稿 v'.$state['draft_version'].'）');
                $db->commit();appConfigFeatureSnapshot($db,true);flash('配置已发布。App 下次读取 /config 时生效（进入前台或重新打开时刷新）。');redirect('config');
            }
            if ($action==='config_rollback') {
                $versionId=filter_var($_POST['version_id']??null,FILTER_VALIDATE_INT);
                $version=$versionId?query("SELECT * FROM app_config_versions WHERE id=? AND config_key='app'",[$versionId])->fetch():null;
                if(!$version) throw new RuntimeException('历史版本不存在。');
                $value=json_decode((string)$version['value_json'],true);
                $config=appConfigNormalize($value);
                $db->beginTransaction();
                $state=appConfigLockedState($db);
                $expected=filter_var($_POST['draft_version']??null,FILTER_VALIDATE_INT);
                if($expected===false||$expected!==$state['draft_version']) throw new RuntimeException('配置已在其他窗口修改，请刷新后重新核对。');
                $newVersion=$state['draft_version']+1;
                $json=json_encode($config,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
                query("INSERT INTO app_config(config_key,draft_json,draft_version,updated_by,updated_at) VALUES('app',?,?,?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE draft_json=VALUES(draft_json),draft_version=VALUES(draft_version),updated_by=VALUES(updated_by),updated_at=UTC_TIMESTAMP()",[$json,$newVersion,(int)$admin['id']]);
                query('INSERT INTO app_config_versions(config_key,version,value_json,action,admin_id,note,created_at) VALUES("app",?,?,"rollback",?,?,UTC_TIMESTAMP())',[$newVersion,$json,(int)$admin['id'],'恢复历史 #'.$versionId]);
                audit('rollback_app_config',null,'历史 #'.$versionId.' 恢复为草稿 v'.$newVersion);
                $db->commit();flash('历史版本已恢复为草稿。请核对后发布，线上版本尚未改变。');redirect('config');
            }
            if ($action==='admin_create') {
                $username=trim((string)($_POST['username']??''));
                $password=(string)($_POST['password']??'');
                $role=(string)($_POST['role']??'readonly');
                if(!preg_match('/^[A-Za-z0-9_.-]{3,60}$/D',$username)) throw new RuntimeException('管理员账号需为 3—60 位字母、数字、下划线、点或短横线。');
                if(strlen($password)<12||strlen($password)>128) throw new RuntimeException('初始密码需为 12—128 字节。');
                if(!isset(adminRoles()[$role])) throw new RuntimeException('管理员角色不正确。');
                if(query('SELECT 1 FROM admin_accounts WHERE username=?',[$username])->fetchColumn()) throw new RuntimeException('该管理员账号已存在。');
                $db->beginTransaction();
                query('INSERT INTO admin_accounts(username,password_hash,role,status,session_version,created_at) VALUES(?,?,?,"active",1,UTC_TIMESTAMP())',[$username,password_hash($password,PASSWORD_DEFAULT),$role]);
                audit('create_admin',null,$username.' · '.adminRoleLabel($role));
                $db->commit();flash('管理员已创建。请通过安全渠道单独交付初始密码，并要求其首次登录后修改。');redirect('admins');
            }
            if ($action==='admin_update') {
                $id=filter_var($_POST['id']??null,FILTER_VALIDATE_INT);
                $role=(string)($_POST['role']??'');
                $status=(string)($_POST['status']??'');
                $row=$id?query('SELECT * FROM admin_accounts WHERE id=?',[$id])->fetch():null;
                if(!$row||!isset(adminRoles()[$role])||!in_array($status,['active','disabled'],true)) throw new RuntimeException('管理员或角色设置不正确。');
                if($id===(int)$admin['id'] && ($role!=='super_admin'||$status!=='active')) throw new RuntimeException('不能停用或降级当前登录账号。');
                if($row['role']==='super_admin'&&$row['status']==='active'&&($role!=='super_admin'||$status!=='active')) {
                    $remaining=(int)query("SELECT COUNT(*) FROM admin_accounts WHERE role='super_admin' AND status='active' AND id<>?",[$id])->fetchColumn();
                    if($remaining<1) throw new RuntimeException('必须保留至少一个启用中的超级管理员。');
                }
                $db->beginTransaction();
                query('UPDATE admin_accounts SET role=?,status=?,session_version=session_version+1 WHERE id=?',[$role,$status,$id]);
                audit('update_admin',null,$row['username'].' · '.adminRoleLabel($row['role']).' → '.adminRoleLabel($role).' · '.$status);
                $db->commit();flash('管理员角色或状态已更新；其现有会话已失效。');redirect('admins');
            }
            if ($action==='admin_password') {
                $id=filter_var($_POST['id']??null,FILTER_VALIDATE_INT);
                $new=(string)($_POST['new_password']??'');
                $row=$id?query('SELECT username FROM admin_accounts WHERE id=?',[$id])->fetch():null;
                if(!$row) throw new RuntimeException('管理员不存在。');
                if(strlen($new)<12||strlen($new)>128) throw new RuntimeException('新密码需为 12—128 字节。');
                $db->beginTransaction();
                query('UPDATE admin_accounts SET password_hash=?,session_version=session_version+1 WHERE id=?',[password_hash($new,PASSWORD_DEFAULT),$id]);
                audit('reset_admin_password',null,$row['username']);
                $db->commit();flash('管理员密码已重置，其现有会话已失效。');redirect('admins');
            }
            if ($action==='password') {
                $old=(string)($_POST['old_password']??''); $new=(string)($_POST['new_password']??'');
                $row=query('SELECT password_hash FROM admin_accounts WHERE id=?',[$admin['id']])->fetch();
                if (!password_verify($old,$row['password_hash'])) throw new RuntimeException('当前密码不正确。');
                if (strlen($new)<12 || strlen($new)>128 || $new!==($_POST['confirm_password']??'')) throw new RuntimeException('新密码需为 12—128 字节，两次输入须一致。');
                $db->beginTransaction();
                query('UPDATE admin_accounts SET password_hash=?,session_version=session_version+1 WHERE id=?',[password_hash($new,PASSWORD_DEFAULT),$admin['id']]);
                audit('change_password'); $db->commit();
                unset($_SESSION['admin_id']); flash('密码已更新，请用新密码登录。'); redirect('login');
            }
        }
    } catch (RuntimeException $e) { if ($db->inTransaction()) $db->rollBack(); $error=$e instanceof PDOException?'操作暂时失败，请稍后重试。':$e->getMessage(); }
}
$page=(string)($_GET['p']??'overview');
if (!$admin) $page='login';
$flash=$_SESSION['flash']??null; unset($_SESSION['flash']);
