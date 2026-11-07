<?php
declare(strict_types=1);

/**
 * Crash-safe media replacement protocol (AUD-002 / FIX-002).
 *
 * A media id keeps its public name (uuid.jpg), but the bytes live in an
 * immutable version file (`uuid.jpg.<nonce>.jpg`). A small pointer file
 * (`uuid.jpg.ref`) names the current version. Legacy single-file media
 * (`uuid.jpg`) stays readable and is migrated on the first replacement.
 *
 * PUT flow: write version file -> write journal -> insert upload event and
 * update user_media inside the transaction -> commit -> switch pointer.
 * The upload-event row is the durable commit marker: if the process stops at
 * any point, recovery checks whether that row survived the transaction and
 * either completes the pointer switch or removes the uncommitted version.
 * The previous bytes are never renamed over, so a failed replace cannot lose
 * the old image.
 */

function mediaStoreIdValid(string $id): bool {
    return preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/D', $id) === 1;
}

/** Serialize every read, replacement, and recovery for one user's media id. */
function mediaStoreLockAcquire(PDO $db, int $userID, string $id): string {
    if ($userID < 1 || !mediaStoreIdValid($id)) throw new RuntimeException('invalid media lock');
    $database = $db->query('SELECT DATABASE()')->fetchColumn();
    $name = 'boji_media_' . substr(hash('sha256', (is_string($database) ? $database : '') . ':' . $userID . ':' . $id), 0, 52);
    $statement = $db->prepare('SELECT GET_LOCK(?, 15)');
    $statement->execute([$name]);
    if ((int)$statement->fetchColumn() !== 1) throw new RuntimeException('media lock unavailable');
    register_shutdown_function(static function() use ($db, $name): void {
        try { $q = $db->prepare('SELECT RELEASE_LOCK(?)'); $q->execute([$name]); } catch (Throwable) {}
    });
    return $name;
}

function mediaStoreLockRelease(PDO $db, string $name): void {
    try {
        $statement = $db->prepare('SELECT RELEASE_LOCK(?)');
        $statement->execute([$name]);
    } catch (Throwable) {
        // Closing the non-persistent request connection also releases the lock.
        error_log('Media lock release deferred to connection close');
    }
}

function mediaStoreRefPath(string $directory, string $id): string {
    return $directory . '/' . $id . '.ref';
}

function mediaStoreJournalPath(string $directory, string $id): string {
    return $directory . '/.' . $id . '.replace.json';
}

/** Return the path that should be served for this media id, or null. */
function mediaStoreResolve(string $directory, string $id): ?string {
    if (!mediaStoreIdValid($id)) return null;
    $ref = mediaStoreRefPath($directory, $id);
    if (is_file($ref) && !is_link($ref)) {
        $version = trim((string)@file_get_contents($ref, false, null, 0, 256));
        $pattern = '/^' . preg_quote($id, '/') . '\.[a-f0-9]{8,32}\.jpg$/D';
        if (preg_match($pattern, $version) === 1) {
            $path = $directory . '/' . $version;
            if (is_file($path) && !is_link($path)) return $path;
        }
    }
    $legacy = $directory . '/' . $id;
    if (is_file($legacy) && !is_link($legacy)) return $legacy;
    return null;
}

/** Version files for an id, including the legacy canonical file. */
function mediaStoreFiles(string $directory, string $id): array {
    $paths = [];
    $legacy = $directory . '/' . $id;
    if (is_file($legacy) || is_link($legacy)) $paths[] = $legacy;
    foreach (glob($directory . '/' . $id . '.*.jpg') ?: [] as $path) {
        if (preg_match('/^' . preg_quote($id, '/') . '\.[a-f0-9]{8,32}\.jpg$/D', basename($path)) === 1) $paths[] = $path;
    }
    return array_values(array_unique($paths));
}

/** Delete every stored representation and any pending journal for an id. */
function mediaStoreRemove(string $directory, string $id): bool {
    if (!mediaStoreIdValid($id)) return false;
    $ok = true;
    foreach (mediaStoreFiles($directory, $id) as $path) {
        if ((is_file($path) || is_link($path)) && !@unlink($path)) $ok = false;
    }
    foreach ([mediaStoreRefPath($directory, $id), mediaStoreJournalPath($directory, $id)] as $path) {
        if ((is_file($path) || is_link($path)) && !@unlink($path)) $ok = false;
    }
    return $ok;
}

function mediaStoreWriteAtomic(string $path, string $contents): bool {
    $temporary = $path . '.' . bin2hex(random_bytes(6)) . '.tmp';
    $handle = @fopen($temporary, 'wb');
    if ($handle === false) return false;
    $ok = fwrite($handle, $contents) === strlen($contents);
    if ($ok && function_exists('fsync')) @fsync($handle);
    $ok = fclose($handle) && $ok;
    if (!$ok || !@rename($temporary, $path)) { @unlink($temporary); return false; }
    @chmod($path, 0640);
    return true;
}

function mediaStoreWriteVersion(string $directory, string $id, string $raw): string {
    $version = $id . '.' . bin2hex(random_bytes(8)) . '.jpg';
    $path = $directory . '/' . $version;
    if (!mediaStoreWriteAtomic($path, $raw)) throw new RuntimeException('media version write failed');
    return $version;
}

/**
 * Persist the new bytes and a journal before the database transaction commits.
 * Returns the journal array; callers must either commit + complete or abort.
 */
function mediaStorePrepare(string $directory, string $id, string $raw, int $eventID): array {
    if (!mediaStoreIdValid($id) || $eventID < 1) throw new RuntimeException('invalid media journal');
    $previous = mediaStoreResolve($directory, $id);
    $version = mediaStoreWriteVersion($directory, $id, $raw);
    $journal = [
        'version' => 1,
        'media_id' => $id,
        'event_id' => $eventID,
        'version_file' => $version,
        'previous_file' => $previous === null ? null : basename($previous),
        'created_at' => time(),
    ];
    $encoded = json_encode($journal, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    if (!mediaStoreWriteAtomic(mediaStoreJournalPath($directory, $id), $encoded)) {
        @unlink($directory . '/' . $version);
        throw new RuntimeException('media journal write failed');
    }
    return $journal;
}

/** Publish the committed version by atomically switching the pointer file. */
function mediaStoreComplete(string $directory, array $journal, ?PDO $db = null, ?int $userID = null): void {
    $id = (string)($journal['media_id'] ?? '');
    $version = (string)($journal['version_file'] ?? '');
    if (!mediaStoreIdValid($id) || preg_match('/^' . preg_quote($id, '/') . '\.[a-f0-9]{8,32}\.jpg$/D', $version) !== 1) return;
    $ref = mediaStoreRefPath($directory, $id);
    if (!mediaStoreWriteAtomic($ref, $version . "\n")) {
        // The committed bytes are still intact under the version file and the
        // journal stays in place; a later read retries the pointer switch.
        error_log('Media pointer switch deferred');
        return;
    }
    $previous = $journal['previous_file'] ?? null;
    if (is_string($previous) && $previous !== '' && $previous !== $version) {
        $oldPath = $directory . '/' . $previous;
        // Never delete a path outside this media id's own files.
        if (basename($oldPath) === $previous && (str_starts_with($previous, $id . '.') || $previous === $id)
            && preg_match('/^' . preg_quote($id, '/') . '(?:\.[a-f0-9]{8,32})?\.jpg$/D', $previous) === 1) {
            @unlink($oldPath);
        }
    }
    $journalPath = mediaStoreJournalPath($directory, $id);
    if (is_file($journalPath)) @unlink($journalPath);
}

/** Remove an uncommitted version and journal; old bytes are untouched. */
function mediaStoreAbort(string $directory, array $journal): void {
    $id = (string)($journal['media_id'] ?? '');
    $version = (string)($journal['version_file'] ?? '');
    if (mediaStoreIdValid($id) && preg_match('/^' . preg_quote($id, '/') . '\.[a-f0-9]{8,32}\.jpg$/D', $version) === 1) {
        @unlink($directory . '/' . $version);
    }
    $journalPath = mediaStoreJournalPath($directory, $id);
    if (mediaStoreIdValid($id) && is_file($journalPath)) @unlink($journalPath);
}

/**
 * Reconcile journals after a crash or before serving an image.
 * A surviving media_upload_events row proves the transaction committed.
 */
function mediaStoreRecover(PDO $db, int $userID, string $directory, ?string $onlyID = null, bool $lockHeld = false): void {
    if (!is_dir($directory)) return;
    $pattern = $onlyID !== null && mediaStoreIdValid($onlyID)
        ? mediaStoreJournalPath($directory, $onlyID)
        : $directory . '/.*.replace.json';
    foreach (glob($pattern) ?: [] as $journalPath) {
        // Lock by the filename before reading the journal. Reading first could
        // retain a stale journal while a replacement completes under the lock.
        if (!preg_match('/^\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg)\.replace\.json$/D', basename($journalPath), $match)) continue;
        $id = $match[1];
        $lockName = $lockHeld ? null : mediaStoreLockAcquire($db, $userID, $id);
        try {
            if (!is_file($journalPath) || is_link($journalPath)) continue;
            $raw = @file_get_contents($journalPath, false, null, 0, 8192);
            $journal = $raw === false ? null : json_decode($raw, true, 8);
            if (!is_array($journal) || ($journal['version'] ?? null) !== 1 || ($journal['media_id'] ?? null) !== $id) { @unlink($journalPath); continue; }
            $version = (string)($journal['version_file'] ?? '');
            if (preg_match('/^' . preg_quote($id, '/') . '\.[a-f0-9]{8,32}\.jpg$/D', $version) !== 1) {
                @unlink($journalPath); continue;
            }
            $eventID = (int)($journal['event_id'] ?? 0);
            $committed = false;
            try {
                // The upload transaction stores the exact new version name. This
                // proof is durable even after media_upload_events is pruned.
                $q = $db->prepare('SELECT version_file FROM user_media WHERE user_id=? AND media_id=?');
                $q->execute([$userID, $id]);
                $storedVersion = $q->fetchColumn();
                if (is_string($storedVersion) && $storedVersion !== '' && hash_equals($storedVersion, $version)) $committed = true;
            } catch (Throwable) {
                // A failed marker lookup is not proof that the upload rolled
                // back. Keep both versions and retry recovery on a later read.
                error_log('Media recovery deferred: version marker unavailable');
                continue;
            }
            if (!$committed && $eventID > 0) {
                try {
                $q = $db->prepare('SELECT 1 FROM media_upload_events WHERE id=? AND user_id=?');
                $q->execute([$eventID, $userID]);
                $committed = (bool)$q->fetchColumn();
                } catch (Throwable) {
                    error_log('Media recovery deferred: upload marker unavailable');
                    continue;
                }
            }
            if ($committed && is_file($directory . '/' . $version)) {
                mediaStoreComplete($directory, $journal, $db, $userID);
            } else {
                mediaStoreAbort($directory, $journal);
            }
        } finally {
            if (is_string($lockName)) mediaStoreLockRelease($db, $lockName);
        }
    }
}
