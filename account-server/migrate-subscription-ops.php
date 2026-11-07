<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require_once __DIR__.'/subscription-ops-migration.php';
$config = is_file(__DIR__.'/config.php') ? require __DIR__.'/config.php' : [];
$dsn = getenv('BOJI_MIGRATION_DSN') ?: ($config['dsn'] ?? '');
if ($dsn === '') { fwrite(STDERR,"数据库配置缺失，未执行迁移。\n"); exit(1); }
try {
    $db = new PDO($dsn, getenv('BOJI_MIGRATION_USER') ?: ($config['db_user'] ?? ''), getenv('BOJI_MIGRATION_PASSWORD') !== false ? getenv('BOJI_MIGRATION_PASSWORD') : ($config['db_password'] ?? ''), [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    if (!in_array('--check',$argv,true)) subscriptionOpsMigrate($db);
    subscriptionOpsCheckSchema($db);
    fwrite(STDOUT,"订阅来源事实表已就绪；未修改历史订单或会员权益。\n");
} catch (Throwable $error) { fwrite(STDERR,"订阅来源迁移失败：".$error->getMessage()."\n"); exit(1); }
