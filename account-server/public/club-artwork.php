<?php
declare(strict_types=1);

// One request can include the same artwork in many seasons. Hash it once per response.
function clubArtworkFiles(?string $name, ?string $directory = null): ?array {
    if ($name === null || $name === '' || basename($name) !== $name || str_contains($name, '\\')) return null;
    $root = realpath($directory ?? dirname(__DIR__).'/admin-media');
    if ($root === false) return null;
    $full = realpath($root.'/'.$name);
    if ($full === false || dirname($full) !== $root || !is_file($full)) return null;
    $thumbnail = $full;
    if (preg_match('/^club-keepsake-\d{2}-[a-z0-9-]+-v20\.png$/D', $name)) {
        $candidate = realpath($root.'/'.substr($name,0,-4).'-thumb.png');
        if ($candidate !== false && dirname($candidate) === $root && is_file($candidate) && filemtime($candidate) >= filemtime($full)) $thumbnail = $candidate;
    }
    return ['full' => $full, 'thumbnail' => $thumbnail];
}

function clubArtworkMetadata(?string $name, ?string $directory = null): array {
    static $cache = [];
    $empty = ['image_version' => null, 'image_sha256' => null, 'thumbnail_sha256' => null];
    $files = clubArtworkFiles($name, $directory);
    if ($files === null) return $empty;
    $key = $files['full'].'|'.$files['thumbnail'];
    if (isset($cache[$key])) return $cache[$key];
    $full = hash_file('sha256', $files['full']);
    $thumbnail = $files['thumbnail'] === $files['full'] ? $full : hash_file('sha256', $files['thumbnail']);
    if ($full === false || $thumbnail === false) return $empty;
    return $cache[$key] = ['image_version' => hash('sha256', $full.':'.$thumbnail), 'image_sha256' => $full, 'thumbnail_sha256' => $thumbnail];
}

function clubArtworkVersionMatches(array $metadata, ?string $requested): bool {
    return $requested === null || (is_string($metadata['image_version']) && hash_equals($metadata['image_version'], $requested));
}
