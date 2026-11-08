<?php
declare(strict_types=1);

/**
 * 后台 AI 完成状态核对 worker（BE-005 修复）。
 *
 * 定时把 ai_user_jobs 里尚未标记完成的任务与本地 AI worker 对账，把已成功的
 * 任务写上 completed_at。请求路径（insights / club-progress）因此只需读本地
 * 库，不再依赖 1~2 秒的同步 HTTP 核验，避免把已完成报告误判成「处理中」或
 * 触发重复生成。
 *
 * 仅在 CLI 运行，由 systemd timer 每 30 秒触发一次。
 */

if (PHP_SAPI !== 'cli') exit(1);
require_once __DIR__ . '/cli-bootstrap.php';
require_once __DIR__ . '/public/ai-response.php';

$config = require __DIR__ . '/config.php';
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
]);

$token = $config['ai_proxy_token'] ?? '';
$base = $config['ai_proxy_base_url'] ?? 'http://127.0.0.1:8787';
if (!is_string($token) || strlen($token) < 24 || !is_string($base)
    || !preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D', $base)) {
    fwrite(STDERR, "ai-completion-refresh: AI worker 未配置，跳过。\n");
    exit(0);
}

$limit = max(1, min(200, (int)($argv[1] ?? 100)));
$rows = $db->query(
    "SELECT user_id,client_job_id,server_job_id,kind FROM ai_user_jobs
      WHERE completed_at IS NULL AND created_at >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 7 DAY)
      ORDER BY created_at ASC LIMIT " . $limit
)->fetchAll();
if (!$rows) { echo json_encode(['candidates'=>0,'marked'=>0]) . "\n"; exit(0); }

$byServer = [];
foreach ($rows as $row) $byServer[strtolower((string)$row['server_job_id'])][] = $row;

$marked = 0;
foreach (array_chunk(array_keys($byServer), 50) as $chunk) {
    $payload = json_encode(['ids' => array_values($chunk)], JSON_THROW_ON_ERROR);
    $context = stream_context_create(['http' => [
        'method' => 'POST',
        'header' => "Content-Type: application/json\r\nAuthorization: Bearer " . $token . "\r\n",
        'content' => $payload,
        'timeout' => 8,
        'ignore_errors' => true,
        'follow_location' => 0,
    ]]);
    $raw = @file_get_contents($base . '/v1/jobs/metadata', false, $context);
    $result = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($result)) continue;
    foreach (($result['items'] ?? []) as $item) {
        if (!is_array($item) || ($item['status'] ?? '') !== 'succeeded') continue;
        $key = strtolower((string)($item['id'] ?? ''));
        if (!isset($byServer[$key])) continue;
        $kinds = array_map('strtolower', aiCompletionKinds((string)($item['kind'] ?? '')));
        foreach ($byServer[$key] as $row) {
            if (!in_array(strtolower((string)$row['kind']), $kinds, true)) continue;
            $db->prepare('UPDATE ai_user_jobs SET completed_at=COALESCE(completed_at,UTC_TIMESTAMP()) WHERE user_id=? AND client_job_id=?')
               ->execute([(int)$row['user_id'], (string)$row['client_job_id']]);
            $marked++;
        }
    }
}
echo json_encode(['candidates'=>count($rows),'marked'=>$marked], JSON_UNESCAPED_UNICODE) . "\n";
