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

echo "Schema portability: $checks assertions passed\n";
