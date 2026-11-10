<?php
declare(strict_types=1);

// Apple public keys only. Signature/issuer/audience/nonce validation remains in
// verifyAppleIdentity; an unknown kid never bypasses a signature check.
final class AppleUnknownKey extends RuntimeException {}
function cachedAppleKeys(string $directory, string $kid, ?callable $fetch = null, ?int $now = null): array {
    $now ??= time();
    if (!preg_match('/^[A-Za-z0-9_-]{1,100}$/D', $kid)) throw new RuntimeException('invalid key id');
    if (is_link($directory)) throw new RuntimeException('unsafe cache');
    if (!is_dir($directory) && !mkdir($directory, 0700, true) && !is_dir($directory)) throw new RuntimeException('cache unavailable');
    $file = $directory . '/keys.json'; $lockFile = $directory . '/keys.lock';
    if (is_link($file) || is_link($lockFile)) throw new RuntimeException('unsafe cache file');
    $lock = fopen($lockFile, 'c');
    if ($lock === false) throw new RuntimeException('cache lock unavailable');
    chmod($lockFile, 0600);
    try {
        if (!flock($lock, LOCK_EX)) throw new RuntimeException('cache lock unavailable');
        $cache = is_file($file) ? json_decode((string)file_get_contents($file), true) : null;
        $keys = is_array($cache['keys'] ?? null) ? $cache['keys'] : [];
        $hasKey = static fn(array $items): bool => count(array_filter($items, static fn($key) => is_array($key) && ($key['kid'] ?? null) === $kid && ($key['kty'] ?? null) === 'RSA')) > 0;
        $fetched = is_int($cache['fetched'] ?? null) ? $cache['fetched'] : 0;
        if ($fetched <= $now && $now - $fetched < 3600 && $hasKey($keys)) return $keys;
        if ($fetched > 0 && $fetched <= $now && $now - $fetched < 30 && !$hasKey($keys)) throw new AppleUnknownKey('unknown key');
        // Throttle both repeated unknown-kid probes and failed network calls.
        $attempt = is_int($cache['attempt'] ?? null) ? $cache['attempt'] : 0;
        if ($attempt <= $now && $now - $attempt < 30) throw new RuntimeException('key refresh deferred');
        $cache = ['keys' => $keys, 'fetched' => $fetched, 'attempt' => $now];
        $write = static function(array $value) use ($file): void {
            $temporary = $file . '.' . bin2hex(random_bytes(6));
            try {
                if (file_put_contents($temporary, json_encode($value, JSON_THROW_ON_ERROR), LOCK_EX) === false) throw new RuntimeException('cache write failed');
                chmod($temporary, 0600);
                if (!rename($temporary, $file)) throw new RuntimeException('cache commit failed');
            } finally { if (is_file($temporary)) unlink($temporary); }
        };
        $write($cache);
        $fetch ??= static function(): string {
            $context = stream_context_create(['http' => ['timeout' => 5, 'user_agent' => 'BojiClub/1.0']]);
            $raw = @file_get_contents('https://appleid.apple.com/auth/keys', false, $context);
            if (!is_string($raw) || strlen($raw) > 65536) throw new RuntimeException('key service unavailable');
            return $raw;
        };
        $raw = $fetch();
        if (!is_string($raw) || strlen($raw) > 65536) throw new RuntimeException('invalid key response');
        $response = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
        if (!is_array($response['keys'] ?? null) || !$response['keys'] || count($response['keys']) > 30) throw new RuntimeException('invalid key response');
        $keys = array_values(array_filter($response['keys'], static fn($key) => is_array($key) && ($key['kty'] ?? null) === 'RSA' && is_string($key['kid'] ?? null) && is_string($key['n'] ?? null) && is_string($key['e'] ?? null)));
        if (!$keys) throw new RuntimeException('empty keys');
        $write(['keys' => $keys, 'fetched' => $now, 'attempt' => $now]);
        if (!$hasKey($keys)) throw new AppleUnknownKey('unknown key');
        return $keys;
    } finally { flock($lock, LOCK_UN); fclose($lock); }
}
