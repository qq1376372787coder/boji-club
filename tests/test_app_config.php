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

// Admin form partial-save: gate flags without a form control must survive.
$carried = appConfigDefaults();
$carried['ai_streaming_v2'] = true;
$carried['ai_router_v3'] = false;
$carried['ai_fast_intent_v1'] = false;
$merged = appConfigDraftMerge($carried, ['ai_enabled' => false, 'club_enabled' => true]);
check($merged['ai_streaming_v2'] === true, 'hidden streaming gate survives draft save');
check($merged['ai_router_v3'] === false, 'hidden router gate survives draft save');
check($merged['ai_fast_intent_v1'] === false, 'hidden fast-intent gate survives draft save');
check($merged['ai_enabled'] === false, 'submitted switch still applies');

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
appConfigFeatureSnapshot($db,true);
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

check(appFeatureEnabled($db,'unknown_switch') === false,'unknown gate fails closed');
appConfigFeatureSnapshot($db,true);
$beforeQueries=(int)$db->query("SHOW SESSION STATUS LIKE 'Questions'")->fetch(PDO::FETCH_NUM)[1];
for($i=0;$i<20;$i++)appFeatureEnabled($db,'ai_enabled');
$afterQueries=(int)$db->query("SHOW SESSION STATUS LIKE 'Questions'")->fetch(PDO::FETCH_NUM)[1];
check($afterQueries-$beforeQueries===1,'twenty gates reuse one snapshot with zero extra SELECTs');
$before=appConfigFeatureSnapshot($db);
$db->exec("UPDATE app_config SET published_version=2 WHERE config_key='app'");
check(appConfigFeatureSnapshot($db)['version']===$before['version'],'snapshot reused within job');
check(appConfigFeatureSnapshot($db,true)['version']===2,'new job refreshes snapshot');
$db->exec("UPDATE app_config SET published_version=3 WHERE config_key='app'");
usleep(1100000);
check(appConfigFeatureSnapshot($db)['version']===3,'long worker job refreshes within bounded TTL');
$db->beginTransaction();
$locked=appConfigLockedState($db);
check($locked['draft_version']===1,'locked read uses committed version');
$db->rollBack();
echo "app config rules passed\n";
