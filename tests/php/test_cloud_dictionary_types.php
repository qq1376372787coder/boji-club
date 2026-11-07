<?php
declare(strict_types=1);
/**
 * Regression for F-01: Swift empty dictionaries must stay JSON objects.
 * PHP decodes {} to [] and would re-encode it as []; the iOS CloudState
 * decoder then throws typeMismatch and every cloud read fails.
 *
 * Run: php tests/php/test_cloud_dictionary_types.php
 */
require_once __DIR__ . '/../../account-server/public/cloud-parts.php';

function expectObject(object $root, array $path): void {
    $cursor = $root;
    foreach ($path as $segment) {
        if (is_object($cursor)) {
            if (!property_exists($cursor, $segment)) { failPath($path, 'missing'); }
            $cursor = $cursor->$segment;
        } elseif (is_array($cursor)) {
            if (!array_key_exists($segment, $cursor)) { failPath($path, 'missing'); }
            $cursor = $cursor[$segment];
        } else {
            failPath($path, get_debug_type($cursor));
        }
    }
    if (!($cursor instanceof stdClass)) { failPath($path, get_debug_type($cursor)); }
}
function failPath(array $path, string $detail): never {
    fwrite(STDERR, 'FAIL ' . implode('.', $path) . ': ' . $detail . ' (must be object)' . PHP_EOL);
    exit(1);
}

$input = json_decode('{
  "planShifts": [{
    "id": "shift-test",
    "createdAt": 1792348618,
    "shiftDays": 1,
    "moves": {"2026-10-20": "2026-10-21"},
    "replaced": {},
    "sourceCycles": {}
  }],
  "weeklyReview": {"date": "2026-10-19", "baseline": {}},
  "weeklyReviewHistory": [{"date": "2026-10-18", "baseline": {}}]
}', true, 64, JSON_THROW_ON_ERROR);

$normalized = cloudPartNormalizeDictionaries($input);
$raw = json_encode($normalized, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
$wire = json_decode($raw, false, 64, JSON_THROW_ON_ERROR);

expectObject($wire, ['planShifts', 0, 'replaced']);
expectObject($wire, ['planShifts', 0, 'sourceCycles']);
expectObject($wire, ['weeklyReview', 'baseline']);
expectObject($wire, ['weeklyReviewHistory', 0, 'baseline']);

$moves = json_encode($wire->planShifts[0]->moves, JSON_UNESCAPED_SLASHES);
if ($moves !== '{"2026-10-20":"2026-10-21"}') {
    fwrite(STDERR, "FAIL non-empty moves changed: " . $moves . PHP_EOL);
    exit(1);
}
echo "CLOUD_DICTIONARY_TYPES_OK" . PHP_EOL;
