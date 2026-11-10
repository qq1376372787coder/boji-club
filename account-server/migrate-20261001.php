<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') exit(1);
$config = require __DIR__.'/config.php';
if (getenv('BOJI_MIGRATION_ROOT') === '1') {
    if (!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/',$config['dsn'],$match)) throw new RuntimeException('Database name missing');
    $socket=getenv('BOJI_MYSQL_SOCKET')?:'/run/mysqld/mysqld.sock';
    if(!str_starts_with($socket,'/')||str_contains($socket,';'))throw new RuntimeException('Invalid database socket path');
    $config['dsn'] = 'mysql:unix_socket='.$socket.';dbname='.$match[1].';charset=utf8mb4';
    $config['db_user']='root'; $config['db_password']='';
}
$db = new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$db->exec(file_get_contents(__DIR__.'/schema.sql'));
$db->exec(file_get_contents(__DIR__.'/admin-schema.sql'));
$db->exec(file_get_contents(__DIR__.'/sync-schema-v59.sql'));
// AUD-021：任务类型只扩不缩。旧版这里无条件改写成不含 coach 的枚举，
// 会让已有 coach 行迁移失败，也会让空库后续无法写入 coach。读取当前
// COLUMN_TYPE，与运行时接受的全部类型取并集；未来新增类型同样保留。
$kindColumn = $db->query("SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ai_user_jobs' AND COLUMN_NAME='kind'")->fetchColumn();
if (is_string($kindColumn)) {
    preg_match_all("/'((?:[^']|'')*)'/", $kindColumn, $matches);
    $existingKinds = array_map(static fn(string $value): string => str_replace("''", "'", $value), $matches[1] ?? []);
    $requiredKinds = ['generate_plan', 'parse_plan', 'food', 'report', 'weekly_review', 'coach'];
    $kinds = array_values(array_unique(array_merge($existingKinds, $requiredKinds)));
    if (array_diff($requiredKinds, $existingKinds)) {
        $quoted = implode(',', array_map(static fn(string $kind): string => "'" . str_replace("'", "''", $kind) . "'", $kinds));
        $db->exec("ALTER TABLE ai_user_jobs MODIFY kind ENUM($quoted) NOT NULL");
    }
}
foreach (['member_admin_profiles','member_admin_notes'] as $table) {
    $name = $table.'_user_fk';
    $check = $db->prepare('SELECT 1 FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND CONSTRAINT_NAME=?'); $check->execute([$name]);
    if (!$check->fetchColumn()) {
        // Orphan records have no account to retain them for. The deploy script backs up the DB first.
        $db->exec("DELETE m FROM $table m LEFT JOIN users u ON u.id=m.user_id WHERE u.id IS NULL");
        $db->exec("ALTER TABLE $table ADD CONSTRAINT $name FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE");
    }
}
$q=$db->query("SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='account_deletions' AND COLUMN_NAME='subject_hash'");
if(!$q->fetchColumn()) $db->exec('ALTER TABLE account_deletions ADD COLUMN subject_hash CHAR(64) NULL');
$rows=$db->query('SELECT d.id,d.user_id,u.apple_subject FROM account_deletions d JOIN users u ON u.id=d.user_id WHERE d.subject_hash IS NULL AND u.apple_subject IS NOT NULL')->fetchAll(PDO::FETCH_ASSOC);
$set=$db->prepare('UPDATE account_deletions SET subject_hash=? WHERE id=? AND subject_hash IS NULL');
foreach($rows as $row) $set->execute([hash_hmac('sha256',$row['user_id'].':apple:'.$row['apple_subject'],$config['otp_secret']),(int)$row['id']]);
$db->exec(file_get_contents(__DIR__.'/migration-v4.sql'));
echo "MIGRATION_OK\n";
