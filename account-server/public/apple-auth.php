<?php
declare(strict_types=1);

function base64urlDecode(string $value): ?string {
    if ($value === '' || !preg_match('/^[A-Za-z0-9_-]+$/D', $value)) return null;
    $decoded = base64_decode(strtr($value, '-_', '+/') . str_repeat('=', (4 - strlen($value) % 4) % 4), true);
    return $decoded === false ? null : $decoded;
}
function derLength(int $length): string {
    if ($length < 128) return chr($length);
    $bytes = '';
    while ($length > 0) { $bytes = chr($length & 255) . $bytes; $length >>= 8; }
    return chr(128 | strlen($bytes)) . $bytes;
}
function appleJwkPem(array $jwk): ?string {
    if (($jwk['kty'] ?? '') !== 'RSA' || ($jwk['alg'] ?? 'RS256') !== 'RS256' || ($jwk['use'] ?? 'sig') !== 'sig') return null;
    $modulus = is_string($jwk['n'] ?? null) ? base64urlDecode($jwk['n']) : null;
    $exponent = is_string($jwk['e'] ?? null) ? base64urlDecode($jwk['e']) : null;
    if ($modulus === null || $exponent === null || strlen($modulus) < 256 || strlen($modulus) > 1024 || strlen($exponent) > 8) return null;
    $integer = static function (string $raw): string {
        $raw = ltrim($raw, "\0");
        if ($raw === '') $raw = "\0";
        if (ord($raw[0]) & 128) $raw = "\0" . $raw;
        return "\x02" . derLength(strlen($raw)) . $raw;
    };
    $rsa = $integer($modulus) . $integer($exponent);
    $rsa = "\x30" . derLength(strlen($rsa)) . $rsa;
    $bitString = "\x00" . $rsa;
    $spki = hex2bin('300d06092a864886f70d0101010500') . "\x03" . derLength(strlen($bitString)) . $bitString;
    $spki = "\x30" . derLength(strlen($spki)) . $spki;
    return "-----BEGIN PUBLIC KEY-----\n" . chunk_split(base64_encode($spki), 64, "\n") . "-----END PUBLIC KEY-----\n";
}

// Pure verification is shared by the HTTP endpoint and signed-fixture regression tests.
function verifyAppleIdentity(string $token, string $nonce, array $clients, array $keys, ?int $now = null): string {
    $now ??= time();
    $parts = explode('.', $token);
    if (count($parts) !== 3 || strlen($token) > 10000 || strlen($nonce) < 16 || strlen($nonce) > 200) throw new RuntimeException('invalid token');
    [$headerPart, $claimPart, $signaturePart] = $parts;
    $header = json_decode(base64urlDecode($headerPart) ?? '', true, 16, JSON_THROW_ON_ERROR);
    $claims = json_decode(base64urlDecode($claimPart) ?? '', true, 16, JSON_THROW_ON_ERROR);
    $signature = base64urlDecode($signaturePart);
    if (!is_array($header) || !is_array($claims) || ($header['alg'] ?? '') !== 'RS256' || !is_string($header['kid'] ?? null) || $signature === null) throw new RuntimeException('invalid signature');
    $pem = null;
    foreach ($keys as $key) if (is_array($key) && ($key['kid'] ?? null) === $header['kid']) { $pem = appleJwkPem($key); break; }
    if ($pem === null || openssl_verify($headerPart . '.' . $claimPart, $signature, $pem, OPENSSL_ALGO_SHA256) !== 1) throw new RuntimeException('invalid signature');
    $aud = $claims['aud'] ?? [];
    $aud = is_array($aud) ? $aud : [$aud];
    if (($claims['iss'] ?? '') !== 'https://appleid.apple.com' || !array_intersect($clients, array_filter($aud, 'is_string'))
        || !is_int($claims['exp'] ?? null) || $claims['exp'] <= $now
        || !is_int($claims['iat'] ?? null) || $claims['iat'] > $now + 30
        || (isset($claims['nbf']) && (!is_int($claims['nbf']) || $claims['nbf'] > $now + 30))
        || !is_string($claims['nonce'] ?? null) || !hash_equals($nonce, $claims['nonce'])
        || !is_string($claims['sub'] ?? null) || $claims['sub'] === '' || strlen($claims['sub']) > 255) throw new RuntimeException('invalid claims');
    return $claims['sub'];
}

function appleIdentity(PDO $db, array $config, array $input): string {
    // Fail closed: without an explicit apple_client_ids config, dev bundle IDs
    // must never be accepted, or a missing production config silently widens
    // Sign in with Apple to any app registered as com.bojiclub.app.dev.
    if (!array_key_exists('apple_client_ids', $config) || !isset($config['apple_client_ids'])) fail('Apple 登录尚未配置。', 503);
    $clients = $config['apple_client_ids'];
    if (is_string($clients)) $clients = [$clients];
    if (!is_array($clients) || !array_filter($clients, 'is_string')) fail('Apple 登录尚未配置。', 503);
    require_once __DIR__ . '/apple-key-cache.php';
    $token = (string)($input['identity_token'] ?? '');
    if (strlen($token) > 10000 || count(explode('.', $token)) !== 3) fail('Apple 登录凭证无效，请重新登录。', 401);
    try { $header = json_decode(base64urlDecode(explode('.', $token)[0]) ?? '', true, 16, JSON_THROW_ON_ERROR); }
    catch (Throwable) { fail('Apple 登录凭证无效，请重新登录。', 401); }
    if (($header['alg'] ?? '') !== 'RS256' || !is_string($header['kid'] ?? null) || !preg_match('/^[A-Za-z0-9_-]{1,100}$/D', $header['kid'])) fail('Apple 登录凭证无效，请重新登录。', 401);
    $cacheDirectory = $config['apple_keys_cache_dir'] ?? dirname(__DIR__) . '/cache/apple-keys';
    try { $keys = cachedAppleKeys($cacheDirectory, $header['kid']); }
    catch (AppleUnknownKey) { fail('Apple 登录凭证无效，请重新登录。', 401); }
    catch (Throwable) { fail('Apple 验证服务暂不可用，请稍后重试。', 503); }
    $nonce = (string)($input['nonce'] ?? '');
    try { $subject = verifyAppleIdentity((string)($input['identity_token'] ?? ''), $nonce, array_filter($clients, 'is_string'), $keys); }
    catch (Throwable) { fail('Apple 登录凭证无效或已过期，请重新登录。', 401); }
    // A signed Apple identity is valid until exp; bind each accepted nonce once
    // so a captured (token, nonce) pair cannot mint unlimited sessions.
    try {
        $db->prepare('INSERT INTO apple_auth_nonces(nonce_hash,expires_at,created_at) VALUES(?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 10 MINUTE),UTC_TIMESTAMP())')
            ->execute([hash('sha256', $nonce)]);
        if (random_int(1, 20) === 1) $db->exec('DELETE FROM apple_auth_nonces WHERE expires_at<UTC_TIMESTAMP() LIMIT 100');
    } catch (PDOException $error) {
        if ((int)($error->errorInfo[1] ?? 0) === 1062) fail('Apple 登录凭证已使用，请重新登录。', 401);
        throw $error;
    }
    return $subject;
}
