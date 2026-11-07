<?php
declare(strict_types=1);

/**
 * Thin loopback client for deterministic engines hosted by the AI worker.
 * Read-only computations only: this helper never executes a business write.
 * A missing/disabled worker returns null and callers keep their local fallback.
 */
function engineRequest(array $config, string $path, array $body, float $timeout = 2.0): ?array {
    $token = $config['ai_proxy_token'] ?? '';
    if (!is_string($token) || strlen($token) < 24) return null;
    $base = $config['ai_proxy_base_url'] ?? 'http://127.0.0.1:8787';
    if (!is_string($base) || !preg_match('#^http://127\.0\.0\.1:[0-9]{2,5}$#D', $base)) return null;
    $payload = json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if (!is_string($payload) || strlen($payload) > 2000000) return null;
    $context = stream_context_create(['http' => [
        'method' => 'POST',
        'header' => "Content-Type: application/json\r\nAuthorization: Bearer " . $token . "\r\n",
        'content' => $payload,
        'timeout' => max(0.5, min(5.0, $timeout)),
        'ignore_errors' => true,
        'follow_location' => 0,
    ]]);
    $raw = @file_get_contents($base . $path, false, $context);
    $status = 0;
    foreach ($http_response_header ?? [] as $header) {
        if (preg_match('#^HTTP/\S+ (\d{3})#', $header, $match)) $status = (int)$match[1];
    }
    if ($status !== 200 || !is_string($raw)) return null;
    $decoded = json_decode($raw, true);
    return is_array($decoded) && is_array($decoded['result'] ?? null) ? $decoded : null;
}
