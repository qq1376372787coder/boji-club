<?php
declare(strict_types=1);
/**
 * AI onboarding V2 additive migration.
 *
 *   BOJI_MIGRATION_ROOT=1 php migrate-onboarding-v2.php --check
 *   BOJI_MIGRATION_ROOT=1 php migrate-onboarding-v2.php --apply
 *
 * --check reports drift and exits 2 without writing. --apply only creates
 * missing tables and job columns; incompatible columns/keys require an explicit repair and cause a nonzero exit. It never drops or rewrites business rows. Safe to run
 * repeatedly. A code rollback does not require dropping these tables: turning
 * onboarding_v2_enabled off keeps old behaviour while sessions/facts are
 * retained for a later resume.
 */
if (PHP_SAPI !== 'cli') exit(1);
$config = getenv('BOJI_MIGRATION_DSN') ? ['dsn'=>getenv('BOJI_MIGRATION_DSN'),'db_user'=>getenv('BOJI_MIGRATION_USER')?:'root','db_password'=>getenv('BOJI_MIGRATION_PASSWORD')?:''] : require __DIR__ . '/config.php';
if (getenv('BOJI_MIGRATION_ROOT') === '1') {
    if (!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/', (string)$config['dsn'], $match)) throw new RuntimeException('Database name missing');
    $socket = getenv('BOJI_MYSQL_SOCKET') ?: '/run/mysqld/mysqld.sock';
    if (!str_starts_with($socket, '/') || str_contains($socket, ';')) throw new RuntimeException('Invalid database socket path');
    $config['dsn'] = 'mysql:unix_socket=' . $socket . ';dbname=' . $match[1] . ';charset=utf8mb4';
    $config['db_user'] = 'root'; $config['db_password'] = '';
}
$apply = in_array('--apply', $argv, true);
$check = !$apply || in_array('--check', $argv, true);
$db = new PDO($config['dsn'], $config['db_user'], $config['db_password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
]);
function onboardingMigrationTableExists(PDO $db, string $table): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');
    $q->execute([$table]);
    return (bool)$q->fetchColumn();
}
function onboardingMigrationColumnExists(PDO $db, string $table, string $column): bool {
    $q = $db->prepare('SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?');
    $q->execute([$table, $column]);
    return (bool)$q->fetchColumn();
}
$columns = [
    'ai_user_jobs' => [
        'purpose' => "VARCHAR(30) NULL AFTER kind",
        'onboarding_session_id' => "CHAR(36) NULL AFTER purpose",
    ],
    'onboarding_assist_usage' => [],
    'user_onboarding_proposals' => ['plan_start_date' => 'DATE NULL'],
];
$columnDrift = [];
foreach ($columns as $table => $definitions) {
    if (!onboardingMigrationTableExists($db, $table)) { $columnDrift[] = "table $table"; continue; }
    foreach ($definitions as $column => $definition) {
        if (!onboardingMigrationColumnExists($db, $table, $column)) $columnDrift[] = "$table.$column";
    }
}
$tables = [
    'user_profile_tombstones','user_profile_documents', 'user_onboarding_sessions', 'user_onboarding_heads',
    'user_onboarding_proposals', 'user_onboarding_requests', 'user_onboarding_messages',
    'onboarding_assist_usage', 'user_onboarding_checkpoints',
];
$existing = [];
$q = $db->query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()");
foreach ($q->fetchAll(PDO::FETCH_COLUMN) as $name) $existing[$name] = true;
$missing = array_values(array_filter($tables, fn($t) => !isset($existing[$t])));
$sqlSource=file_get_contents(__DIR__.'/migrations/20261026-onboarding-v2.sql');
if($sqlSource===false)throw new RuntimeException('migration sql missing');
preg_match_all('/CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\((.*?)\) ENGINE=/s',$sqlSource,$tableDefinitions,PREG_SET_ORDER);
$expectedColumns=[];
foreach($tableDefinitions as $match){
 preg_match_all('/(?:^|,\s*|\n\s*)([a-z_]+)\s+((?:BIGINT|TINYINT|INT|CHAR|VARCHAR|DATETIME|DATE|MEDIUMTEXT|TEXT|ENUM)(?:\([^)]*\))?(?:\s+UNSIGNED)?)([^,\n]*)/i',$match[2],$defs,PREG_SET_ORDER);
 foreach($defs as $def)$expectedColumns[$match[1]][$def[1]]=['type'=>strtolower(preg_replace('/\s+/',' ',trim($def[2]))),'nullable'=>!preg_match('/NOT NULL|PRIMARY KEY/i',$def[3])];
}
/** Check table-scoped columns, keys and cascading ownership, before AND after apply. */
function onboardingMigrationStructuralDrift(PDO $db,array $definitions,array $expected):array {
 $drift=[];
 foreach($definitions as $def){
  $table=$def[1];$body=$def[2];if(!onboardingMigrationTableExists($db,$table))continue;
  $q=$db->prepare('SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');$q->execute([$table]);$actual=[];foreach($q as $row)$actual[$row['COLUMN_NAME']]=$row;
  foreach($expected[$table] as $column=>$spec){
   if(!isset($actual[$column])){$drift[]=$table.'.'.$column.':missing';continue;}
   $type=strtolower(preg_replace('/\b(bigint|tinyint|int)\(\d+\)/i','$1',$actual[$column]['COLUMN_TYPE']));
   if($type!==$spec['type']||($actual[$column]['IS_NULLABLE']==='YES')!==$spec['nullable'])$drift[]=$table.'.'.$column.':definition';
  }
  $keys=[];
  if(preg_match('/PRIMARY KEY\s*\(([^)]+)\)/',$body,$primary))$keys['PRIMARY']=['cols'=>$primary[1],'unique'=>true];
  else foreach($expected[$table] as $column=>$spec)if(preg_match('/\b'.preg_quote($column,'/').'\s+[^,\n]*PRIMARY KEY/',$body))$keys['PRIMARY']=['cols'=>$column,'unique'=>true];
  preg_match_all('/(UNIQUE\s+)?KEY\s+(\w+)\s*\(([^)]+)\)/',$body,$matches,PREG_SET_ORDER);
  foreach($matches as $m)$keys[$m[2]]=['cols'=>$m[3],'unique'=>trim($m[1])==='UNIQUE'];
  foreach($keys as $name=>$spec){
   $q=$db->prepare('SELECT COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND INDEX_NAME=? ORDER BY SEQ_IN_INDEX');$q->execute([$table,$name]);$rows=$q->fetchAll();
   $cols=array_map('trim',explode(',',$spec['cols']));
   if(array_column($rows,'COLUMN_NAME')!==$cols||!$rows||((int)$rows[0]['NON_UNIQUE']===0)!==$spec['unique'])$drift[]=$table.'.index:'.$name;
  }
  preg_match_all('/CONSTRAINT\s+(\w+)\s+FOREIGN KEY\s*\(([^)]+)\)\s+REFERENCES\s+(\w+)\s*\(([^)]+)\)/',$body,$fks,PREG_SET_ORDER);
  foreach($fks as $fk){
   $q=$db->prepare('SELECT r.DELETE_RULE,k.COLUMN_NAME,k.REFERENCED_TABLE_NAME,k.REFERENCED_COLUMN_NAME FROM information_schema.REFERENTIAL_CONSTRAINTS r JOIN information_schema.KEY_COLUMN_USAGE k ON k.CONSTRAINT_SCHEMA=r.CONSTRAINT_SCHEMA AND k.TABLE_NAME=r.TABLE_NAME AND k.CONSTRAINT_NAME=r.CONSTRAINT_NAME WHERE r.CONSTRAINT_SCHEMA=DATABASE() AND r.TABLE_NAME=? AND r.CONSTRAINT_NAME=?');$q->execute([$table,$fk[1]]);$row=$q->fetch();
   if(!$row||$row['DELETE_RULE']!=='CASCADE'||$row['COLUMN_NAME']!==trim($fk[2])||$row['REFERENCED_TABLE_NAME']!==$fk[3]||$row['REFERENCED_COLUMN_NAME']!==trim($fk[4]))$drift[]=$table.'.foreign_key:'.$fk[1];
  }
 }
 return $drift;
}
$structuralDrift=onboardingMigrationStructuralDrift($db,$tableDefinitions,$expectedColumns);
$drift = array_merge($missing, $columnDrift, $structuralDrift);
if ($check) {
    echo json_encode(['status' => $drift ? 'DRIFT' : 'SCHEMA_OK', 'missing_tables' => $missing, 'missing_columns' => $columnDrift, 'structural_drift'=>$structuralDrift], JSON_UNESCAPED_UNICODE) . "\n";
    exit($drift ? 2 : 0);
}
$sql = file_get_contents(__DIR__ . '/migrations/20261026-onboarding-v2.sql');
if ($sql === false) throw new RuntimeException('migration sql missing');
$lines = array_filter(array_map('trim', explode("\n", $sql)), fn($line) => $line !== '' && !str_starts_with($line, '--'));
foreach (array_filter(array_map('trim', explode(';', implode("\n", $lines)))) as $statement) {
    if ($statement === '') continue;
    $db->exec($statement);
}
$addedColumns = [];
foreach ($columns as $table => $definitions) {
    foreach ($definitions as $column => $definition) {
        if (onboardingMigrationColumnExists($db, $table, $column)) continue;
        $db->exec("ALTER TABLE `$table` ADD COLUMN `$column` $definition");
        $addedColumns[] = "$table.$column";
    }
}
$missingAfter = [];
$missingAfter=onboardingMigrationStructuralDrift($db,$tableDefinitions,$expectedColumns);
foreach ($tables as $table) {
    if (!onboardingMigrationTableExists($db, $table)) $missingAfter[] = $table;
}
foreach ($columns as $table => $definitions) {
    foreach ($definitions as $column => $definition) {
        if (!onboardingMigrationColumnExists($db, $table, $column)) $missingAfter[] = "$table.$column";
    }
}
echo json_encode(['status' => $missingAfter ? 'FAILED' : 'APPLIED', 'created' => $missing, 'added_columns' => $addedColumns, 'missing_after' => $missingAfter], JSON_UNESCAPED_UNICODE) . "\n";
exit($missingAfter ? 1 : 0);
