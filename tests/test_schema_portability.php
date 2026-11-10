<?php
declare(strict_types=1);
/**
 * Schema portability guard.
 *
 * Two defects hid behind a green CI for a long time:
 *
 *  1. schema.sql is written for MariaDB and uses "ADD COLUMN / ADD KEY IF NOT
 *     EXISTS", which MySQL 8.x rejects with 1064. The production bootstrap
 *     (migrate-20261001.php) executed the file raw, so a MySQL-backed
 *     deployment could not create the schema at all. The test harness used to
 *     hide this by rewriting the SQL with a regex of its own — i.e. the test
 *     no longer exercised the production path.
 *
 *  2. ai_provider_consents / ai_context_bundles / ai_stream_leases were only
 *     created by migrate-ai-context.php, which no build path and no schema
 *     file covered. aiProviderConsentAssert queries ai_provider_consents on
 *     every parented action, so a missing table took the whole AI action path
 *     down.
 *
 * This suite pins both: the schema files must load through the shared
 * loader, and the AI tables must exist in a schema built the same way.
 */
if(!getenv('BOJI_TEST_DSN_BASE')){fwrite(STDERR,"Use an isolated BOJI_TEST_DSN_BASE.\n");exit(2);}
require __DIR__.'/php_test_bootstrap.php';

$root = dirname(__DIR__);
$checks = 0;
function ok(bool $value, string $message): void {
    global $checks;
    if (!$value) throw new RuntimeException('FAIL: '.$message);
    $checks++;
}

// The production bootstrap must load schema files through the shared loader.
$migration = file_get_contents($root.'/account-server/migrate-20261001.php') ?: '';
ok(str_contains($migration,'bojiApplySchemaFile'),'production bootstrap uses the shared schema loader');
ok(!str_contains($migration,"exec(file_get_contents(__DIR__.'/schema.sql'))"),'production bootstrap does not execute schema.sql raw');
ok(str_contains($migration,'bojiMigrationRootConfig'),'production bootstrap keeps the root connection contract');

// The loader must translate MariaDB-only DDL into portable DDL.
require_once $root.'/account-server/schema-loader.php';
$db = bojiTestDatabase('bojiclub_it');

// The AI tables must exist in a schema built through the production path.
foreach (['ai_provider_consents','ai_context_bundles','ai_stream_leases'] as $table) {
    $query = $db->prepare('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?');
    $query->execute([$table]);
    ok((int)$query->fetchColumn()===1,$table.' exists in a schema built from the SQL files');
}

// A column that already exists must be skipped rather than raise a syntax
// error on MySQL 8.x, and a missing column must still be added.
$db->exec('CREATE TABLE IF NOT EXISTS boji_portability_probe (id INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=InnoDB');
$probe = 'ALTER TABLE boji_portability_probe ADD COLUMN IF NOT EXISTS label VARCHAR(40) NULL';
$portable = bojiSchemaPortableStatement($db, $probe);
ok(!str_contains(strtoupper($portable),'IF NOT EXISTS'),'MariaDB-only ADD COLUMN is rewritten to portable DDL');
$db->exec($portable);
$again = bojiSchemaPortableStatement($db, $probe);
ok($again==='','an existing column makes the statement a no-op');
$db->exec('DROP TABLE boji_portability_probe');

// Statement splitting must be quote- and comment-aware.
//
// A naive split on ';' broke the real schema.sql: one comment line contained a
// semicolon, so the text after it became a separate statement and the server
// answered with a syntax error. The same class of bug appears when a regex
// such as \R is used to split lines, because in PCRE without the UTF mode \R
// also matches the byte 0x85 — which occurs as a continuation byte inside
// ordinary Chinese characters ("光" is E5 85 89).
$split = bojiSchemaStatements(
    "-- 说明：这里有一个分号；不该切开\n".
    "CREATE TABLE a (id INT);\n".
    "# 井号注释；也不该切开\n".
    "INSERT INTO a VALUES ('含分号；的字符串');\n".
    "-- (曝光→接受→执行→结果 chain)\n".
    "/* 块注释；也不该切开 */\n".
    "ALTER TABLE a ADD COLUMN x INT;"
);
ok(count($split)===3,'only real statement ends split the file');
ok(str_starts_with($split[0],'CREATE TABLE a'),'the first statement is the CREATE TABLE');
ok(str_contains($split[1],"'含分号；的字符串'"),'a semicolon inside a string literal does not end the statement');
ok(str_starts_with($split[2],'ALTER TABLE a'),'comments between statements are dropped');

// The byte 0x85 must never be treated as a line break.
$nel = bojiSchemaStatements("-- 曝光→接受 chain\nSELECT 1;");
ok(count($nel)===1 && str_starts_with($nel[0],'SELECT 1'),'a Chinese character containing 0x85 does not split the statement');

echo "Schema portability: $checks assertions passed\n";
