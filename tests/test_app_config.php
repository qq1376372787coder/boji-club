<?php
declare(strict_types=1);
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/app-config.php';

$db = bojiTestDatabase('bojiclub_app_config_test');
$db->exec('DELETE FROM app_config');
$db->exec('DELETE FROM app_config_versions');

function check(bool $condition, string $message): void {
    if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); }
}

$defaults = appConfigPublished($db);
check($defaults['version'] === 0, 'default version is 0');
check($defaults['config']['ai_enabled'] === true, 'AI defaults to enabled');
check($defaults['config']['club_enabled'] === true, 'club defaults to enabled');
check($defaults['config']['minimum_build'] === 0, 'minimum build defaults to 0');
check($defaults['config']['announcement']['enabled'] === false, 'announcement defaults to disabled');

$draft = appConfigNormalize([
    'ai_enabled' => false,
    'club_enabled' => true,
    'minimum_build' => 112,
    'latest_build' => 113,
    'announcement' => ['enabled' => true, 'title' => '内测更新', 'body' => '请更新到最新构建。'],
]);
$json = json_encode($draft, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
$publishedJson = json_encode(appConfigDefaults(), JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
$db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,0,UTC_TIMESTAMP(),NULL)")
    ->execute([$json, $publishedJson]);
$state = appConfigState($db);
check($state['dirty'] === true, 'draft differs from published');
check($state['draft']['ai_enabled'] === false, 'draft stores new value');
check(appConfigPublished($db)['config']['ai_enabled'] === true, 'draft is not published');
check(appFeatureEnabled($db, 'club_enabled') === true, 'published club flag is read');


$db->prepare("UPDATE app_config SET published_json=?,published_version=1,published_at=UTC_TIMESTAMP() WHERE config_key='app'")->execute([$json]);
$published = appConfigPublished($db);
check($published['version'] === 1, 'published version is 1');
check($published['config']['ai_enabled'] === false, 'published AI flag changes');
check($published['config']['minimum_build'] === 112, 'published build gate');
check(appFeatureEnabled($db, 'ai_enabled') === false, 'feature gate reads the published switch');

foreach ([
    [['unknown' => true], 'unknown key'],
    [['ai_enabled' => 1], 'non-boolean switch'],
    [['minimum_build' => -1], 'negative build'],
    [['latest_build' => 10, 'minimum_build' => 11], 'minimum above latest'],
    [['announcement' => ['enabled' => true, 'title' => '', 'body' => 'x']], 'enabled announcement without title'],
    [['announcement' => ['enabled' => false, 'title' => str_repeat('a', 81), 'body' => 'x']], 'oversized title'],
] as [$bad, $label]) {
    try { appConfigNormalize($bad); check(false, "accepted $label"); }
    catch (RuntimeException) { /* expected */ }
}

$versionCount = (int)$db->query('SELECT COUNT(*) FROM app_config_versions')->fetchColumn();
check($versionCount === 0, 'no version rows were written by read helpers');

echo "app config rules passed\n";
