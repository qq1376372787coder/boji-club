<?php
declare(strict_types=1);
/** IA-08: Fitness progression, Personal ranking/memory policy, active learning, compensation entry. */
require __DIR__ . '/php_test_bootstrap.php';
require __DIR__ . '/../account-server/public/app-config.php';
require __DIR__ . '/../account-server/public/action-support.php';
require __DIR__ . '/../account-server/public/ai-response.php';
require __DIR__ . '/../account-server/public/ai-conversations.php';
require __DIR__ . '/../account-server/public/ai-entitlements.php';
require __DIR__ . '/../account-server/public/ai-memory.php';
require __DIR__ . '/../account-server/public/insights.php';
require __DIR__ . '/../account-server/public/cloud-parts.php';
require __DIR__ . '/../account-server/public/capability-registry.php';
require __DIR__ . '/../account-server/public/ai-router.php';
require __DIR__ . '/../account-server/public/ai-runs.php';
function fail(string $message, int $code = 400): never { throw new RuntimeException($message, $code); }
function lockActiveUser(PDO $db, int $uid): void { $q=$db->prepare("SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE");$q->execute([$uid]);if(!$q->fetchColumn())throw new RuntimeException('inactive'); }
function respond(int $status, array $body = []): never { throw new RuntimeException('respond:' . $status, $status); }
function check(bool $condition, string $message): void { if (!$condition) { fwrite(STDERR, "FAIL: $message\n"); exit(1); } }

$base = new PDO(getenv('BOJI_TEST_DSN_BASE'), getenv('BOJI_TEST_DB_USER') ?: 'root', getenv('BOJI_TEST_DB_PASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$base->exec('DROP DATABASE IF EXISTS bojiclub_intelligence_test');
$base->exec('CREATE DATABASE bojiclub_intelligence_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
$db = bojiTestDatabase('bojiclub_intelligence_test');
bojiTestSchema($db, __DIR__ . '/../account-server');
$db->prepare("INSERT INTO users(phone,status,created_at,updated_at) VALUES('13910000041','active',UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute();
$uid = (int)$db->lastInsertId();
$today = (new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
$exerciseId = actionUUID('exercise/fixture-1');
$sessionId = actionUUID('session/fixture-1');
$state = ['profile'=>['age'=>28], 'days' => [$today => [
    'exercises' => [[
        'id' => $exerciseId, 'name' => '平板杠铃卧推', 'muscle' => '胸', 'libraryID' => '0025', 'workoutSessionID' => $sessionId,
        'sets' => [
            ['id' => actionUUID('set/fixture-1'), 'weight' => 50, 'reps' => 10, 'completed' => true],
            ['id' => actionUUID('set/fixture-2'), 'weight' => 50, 'reps' => 10, 'completed' => true],
            ['id' => actionUUID('set/fixture-3'), 'weight' => 50, 'reps' => 10, 'completed' => true],
        ],
    ]],
    'workoutSessions' => [['id' => $sessionId, 'savedAt' => time()]],
    'workoutSavedAt' => time(),
    'meals' => [],
]]];
$previousDate = (new DateTimeImmutable($today))->modify('-2 days')->format('Y-m-d');
$previousDay = $state['days'][$today];
$previousSession = actionUUID('session/fixture-previous');
$previousDay['workoutSessions'][0]['id'] = $previousSession;
$previousDay['exercises'][0]['workoutSessionID'] = $previousSession;
$state['days'][$previousDate] = $previousDay;
$db->prepare('INSERT INTO app_states(user_id,revision,state_json,updated_at) VALUES(?,1,?,UTC_TIMESTAMP())')->execute([$uid, json_encode($state, JSON_UNESCAPED_UNICODE)]);
$db->prepare("INSERT INTO user_action_preferences(user_id,fast_records,time_zone,weight_unit,proactive_learning,updated_at) VALUES(?,0,'Asia/Shanghai','kg',1,UTC_TIMESTAMP())")->execute([$uid]);
$published = appConfigDefaults(); $published['ai_enabled']=true; $published['action_system_enabled']=true;
$db->prepare("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) VALUES('app',?,?,1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")->execute([json_encode($published),json_encode($published)]);
$GLOBALS['config'] = ['otp_secret'=>str_repeat('x',64), 'ai_proxy_base_url'=>'http://127.0.0.1:18792',
                      'ai_proxy_token'=>'independent-audit-loopback-only-token-1234', 'membership_enforcement'=>false];

// Readiness: real confirmed facts reach the engine; acute symptoms override load.
$advice = aiRouterAdvice($db, ['id'=>$uid], ['question'=>'今天有点累，能正常练吗']);
check(is_array($advice['data']['engine'] ?? null), 'readiness engine result is present in the response');
check(in_array($advice['data']['engine']['decision'] ?? '', ['ASK_FOLLOWUP','CONSIDER_MODIFIED','CONSIDER_REST','TRAIN_AS_PLANNED'], true), 'readiness decision is explicit');
$acute = aiRouterAdvice($db, ['id'=>$uid], ['question'=>'我现在胸部疼痛，喘不过气，还能练吗']);
check(($acute['data']['engine']['decision'] ?? '') === 'SAFETY_ESCALATION', 'acute symptoms escalate');
check(count($acute['card']['payload']['options']) === 1 && $acute['card']['payload']['options'][0]['choice'] === 'medical', 'acute advice offers only medical escalation');

// Progression: authoritative sets + deterministic rule → existing AdviceCard.
$progress = aiRouterRouteOne($db, ['id'=>$uid], [
    'capability'=>'fitness.suggest_progression',
    'input'=>['library_id'=>'0025','effort_acceptable'=>true,'target_reps'=>8],
]);
check(($progress['status'] ?? '') === 'completed', 'progression capability completes');
check(($progress['card']['payload']['engine']['decision'] ?? '') === 'MAY_SUGGEST_SMALL_PROGRESSION', 'progression suggests only a small optional increase');
check(($progress['card']['payload']['engine']['auto_apply'] ?? true) === false, 'progression never auto-applies');

// Compensation entry exists and refuses when there is no executed reschedule.
$compensation = aiRouterRouteOne($db, ['id'=>$uid], ['capability'=>'schedule.preview_compensation','input'=>[]]);
check(in_array($compensation['status'] ?? '', ['needs_clarification','clarification','rejected'], true), 'compensation without an executed change asks for clarification');

// Insight ranking uses the deterministic engine and respects active-learning off.
$insight = insightHomePick($db, $uid, $state, $today);
check(is_array($insight), 'a verified insight is selected');
$db->prepare('UPDATE user_action_preferences SET proactive_learning=0 WHERE user_id=?')->execute([$uid]);
check(insightHomePick($db, $uid, $state, $today) === null, 'proactive learning off suppresses new insights');
$db->prepare('UPDATE user_action_preferences SET proactive_learning=1 WHERE user_id=?')->execute([$uid]);

// Memory trust: user-authored content is not overwritten by an AI extraction.
$key = aiMemoryKey($uid, 'goal', 'goal');
$db->prepare("INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,source_revision,created_at,updated_at) VALUES(?,?,'goal','active','user','用户确认：保持体重',100,'[]',?,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
   ->execute([actionUUID('mem-user-goal'), $uid, $key]);
aiMemoryUpsert($db, $uid, 'goal', 'AI 推断：想增肌', 60, [['type'=>'fixture']], 'goal', 2);
$content = $db->prepare('SELECT content FROM user_memory_items WHERE user_id=? AND idempotency_key=?');
$content->execute([$uid, $key]);
check($content->fetchColumn() === '用户确认：保持体重', 'AI extraction cannot overwrite a user-authored goal');

// Extracted memory can still be updated by newer extracted evidence (policy is not a blanket block).
$key2 = aiMemoryKey($uid, 'habit', 'habit');
$db->prepare("INSERT INTO user_memory_items(memory_id,user_id,kind,status,origin,content,confidence,evidence_json,idempotency_key,source_revision,created_at,updated_at) VALUES(?,?,'habit','active','extracted','常在晚上训练',60,'[]',?,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
   ->execute([actionUUID('mem-ai-habit'), $uid, $key2]);
aiMemoryUpsert($db, $uid, 'habit', '常在早上训练', 70, [['type'=>'fixture']], 'habit', 2);
$content2 = $db->prepare('SELECT content FROM user_memory_items WHERE user_id=? AND idempotency_key=?');
$content2->execute([$uid, $key2]);
check($content2->fetchColumn() === '常在早上训练', 'newer extracted habit can update an extracted memory');
// Compensation for an executed one-off reschedule creates a NEW reverse proposal.
$fromDate = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('+1 day')->format('Y-m-d');
$toDate = (new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai')))->modify('+3 day')->format('Y-m-d');
$compState = json_decode((string)$db->query('SELECT state_json FROM app_states WHERE user_id=' . $uid)->fetchColumn(), true);
$compState['days'][$fromDate] = ['exercises'=>[[
    'id'=>strtoupper(actionUUID('comp/ex')), 'name'=>'深蹲','muscle'=>'腿','workoutSessionID'=>strtoupper(actionUUID('comp/session')),
    'sets'=>[['id'=>strtoupper(actionUUID('comp/set')),'weight'=>20,'reps'=>10,'completed'=>false]],
]], 'meals'=>[], 'workoutSessions'=>[['id'=>strtoupper(actionUUID('comp/session'))]]];
$compState['days'][$toDate] = ['exercises'=>[], 'meals'=>[]];
$db->prepare('UPDATE app_states SET revision=revision+1,state_json=? WHERE user_id=?')->execute([json_encode($compState, JSON_UNESCAPED_UNICODE), $uid]);
$movePreview = aiRouterRouteOne($db, ['id'=>$uid], ['capability'=>'schedule.preview_change', 'input'=>['moves'=>[['from'=>$fromDate,'to'=>$toDate]]]]);
$moved = actionConfirmProposal($db, ['id'=>$uid], $movePreview['proposal_id']);
$movedCommand = $moved['commandId'];
$comp = aiRouterRouteOne($db, ['id'=>$uid], ['capability'=>'schedule.preview_compensation','input'=>['command_id'=>$movedCommand]]);
check(($comp['status'] ?? '') === 'awaiting_confirmation', 'compensation creates an awaiting-confirmation proposal');
$storedComp = aiProposalFetch($db, $uid, (string)($comp['proposal_id'] ?? ''));
check(($storedComp['payload']['moves'][0]['from'] ?? '') === $toDate && ($storedComp['payload']['moves'][0]['to'] ?? '') === $fromDate, 'compensation reverses the executed move');
check(($storedComp['status'] ?? '') === 'awaiting_confirmation', 'compensation is not auto-applied');

// Nutrition formal chain: trusted source + review flag survive draft → MealEntry.
$mealProposal = aiProposalCreate($db, $uid, 'meal_draft', [
    'date'=>$today,
    'meals'=>[[
        'name'=>'米饭','category'=>'午餐','calories'=>232,'protein'=>5.2,'carbs'=>51.8,'fat'=>0.6,
        'estimated'=>false,'requiresReview'=>false,'nutritionSources'=>['FIXTURE_CN_FOOD'],
        'components'=>[[
            'id'=>'c1','name'=>'米饭','amount'=>200,'unit'=>'g','calories'=>232,'protein'=>5.2,
            'carbs'=>51.8,'fat'=>0.6,'basis'=>'visible','details'=>[],
            'sourceKind'=>'database','sourceDatabase'=>'FIXTURE_CN_FOOD','sourceVersion'=>'2026.10',
            'confidenceLow'=>220,'confidenceHigh'=>243,'uncertaintyFlags'=>[],'requiresReview'=>false,
        ]],
    ]],
], [], $conversation ?? null, null);
$confirmedMeal = actionConfirmProposal($db, ['id'=>$uid], $mealProposal['proposal_id']);
check(($confirmedMeal['status'] ?? '') === 'succeeded', 'meal proposal confirms');
$stateRow = $db->prepare('SELECT state_json FROM app_states WHERE user_id=?'); $stateRow->execute([$uid]);
$savedState = json_decode((string)$stateRow->fetchColumn(), true);
$savedMeal = $savedState['days'][$today]['meals'][0] ?? [];
check(($savedMeal['components'][0]['sourceDatabase'] ?? '') === 'FIXTURE_CN_FOOD', 'meal entry keeps trusted source');
check(array_key_exists('requiresReview', $savedMeal), 'meal entry keeps review state');

echo "INTELLIGENCE_CLOSURE_OK\n";
