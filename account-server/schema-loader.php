<?php
declare(strict_types=1);

/**
 * Portable schema loader (shared by the production bootstrap and the test
 * harness so both exercise exactly the same code path).
 *
 * schema.sql is written for MariaDB: `ALTER TABLE ... ADD COLUMN IF NOT
 * EXISTS` and `ADD [UNIQUE] KEY|INDEX IF NOT EXISTS` are MariaDB-only DDL
 * extensions. MySQL 8.x rejects them with 1064 (syntax error), so a
 * MySQL-backed deployment cannot bootstrap the schema at all — the production
 * migration used to fail on the first such statement.
 *
 * The loader rewrites those statements into an information_schema existence
 * probe plus the portable plain DDL, and tolerates duplicate column / index
 * errors (1060, 1061, 1091) so a re-run stays idempotent on both engines.
 * Everything else is executed statement by statement, which also stops one
 * bad statement from silently aborting the rest of the file.
 */

/** Split a schema file into executable statements; comment-only lines are dropped. */
function bojiSchemaStatements(string $sql): array {
    $kept = [];
    foreach (preg_split('/\R/', $sql) ?: [] as $line) {
        if (preg_match('/^\s*--/', $line)) continue;
        $kept[] = $line;
    }
    $statements = [];
    foreach (explode(';', implode("\n", $kept)) as $part) {
        $trimmed = trim($part);
        if ($trimmed !== '') $statements[] = $trimmed;
    }
    return $statements;
}

function bojiSchemaColumnExists(PDO $db, string $table, string $column): bool {
    $query = $db->prepare('SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?');
    $query->execute([$table, $column]);
    return (bool)$query->fetchColumn();
}

function bojiSchemaIndexExists(PDO $db, string $table, string $index): bool {
    $query = $db->prepare('SELECT 1 FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND INDEX_NAME=?');
    $query->execute([$table, $index]);
    return (bool)$query->fetchColumn();
}

/**
 * Rewrite MariaDB-only DDL into portable DDL. Returns an empty string when
 * the target schema already has the column / index and the statement is a
 * no-op.
 */
function bojiSchemaPortableStatement(PDO $db, string $statement): string {
    // ALTER TABLE t ADD COLUMN IF NOT EXISTS col <definition>
    if (preg_match('/^ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+`?([A-Za-z0-9_]+)`?\s*(.*)$/is', $statement, $match)) {
        if (bojiSchemaColumnExists($db, $match[1], $match[2])) return '';
        return 'ALTER TABLE `'.$match[1].'` ADD COLUMN `'.$match[2].'` '.$match[3];
    }
    // ALTER TABLE t ADD [UNIQUE] KEY|INDEX IF NOT EXISTS name <definition>
    if (preg_match('/^ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?\s+ADD\s+(UNIQUE\s+)?(?:KEY|INDEX)\s+IF\s+NOT\s+EXISTS\s+`?([A-Za-z0-9_]+)`?\s*(.*)$/is', $statement, $match)) {
        if (bojiSchemaIndexExists($db, $match[1], $match[3])) return '';
        $unique = trim($match[2]) !== '' ? 'UNIQUE ' : '';
        return 'ALTER TABLE `'.$match[1].'` ADD '.$unique.'KEY `'.$match[3].'` '.$match[4];
    }
    return $statement;
}

/** Apply one schema file. Returns the number of statements actually executed. */
function bojiApplySchemaFile(PDO $db, string $file): int {
    $sql = @file_get_contents($file);
    if ($sql === false) throw new RuntimeException('schema file unreadable: '.$file);
    $executed = 0;
    foreach (bojiSchemaStatements($sql) as $statement) {
        $portable = bojiSchemaPortableStatement($db, $statement);
        if ($portable === '') continue;
        try {
            $db->exec($portable);
            $executed++;
        } catch (PDOException $error) {
            // 1060 duplicate column, 1061 duplicate key, 1091 duplicate index:
            // the target schema already has it, which is the desired end state.
            if (!in_array((int)($error->errorInfo[1] ?? 0), [1060, 1061, 1091], true)) throw $error;
        }
    }
    return $executed;
}

/**
 * Root migration connection for deploy scripts: the deployed config may point
 * at a socket-authenticated user that cannot run DDL, so the deploy runs as
 * root over the unix socket instead.
 */
function bojiMigrationRootConfig(array $config): array {
    if (!preg_match('/(?:^|;)dbname=([A-Za-z0-9_]+)(?:;|$)/', (string)$config['dsn'], $match)) {
        throw new RuntimeException('Database name missing');
    }
    $socket = getenv('BOJI_MYSQL_SOCKET') ?: '/run/mysqld/mysqld.sock';
    if (!str_starts_with($socket, '/') || str_contains($socket, ';')) {
        throw new RuntimeException('Invalid database socket path');
    }
    $config['dsn'] = 'mysql:unix_socket='.$socket.';dbname='.$match[1].';charset=utf8mb4';
    $config['db_user'] = 'root';
    $config['db_password'] = '';
    return $config;
}
