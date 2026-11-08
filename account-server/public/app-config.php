<?php
declare(strict_types=1);

/**
 * A deliberately small published/draft configuration surface.
 *
 * Only values that are safe for an unauthenticated client may live here.
 * Secrets (database, AI owner token, APNs key) stay in config.php and are
 * never readable or writable from the admin UI.
 */
function appConfigDefinitions(): array {
    return [
        'ai_enabled' => ['type' => 'bool', 'default' => true],
        'action_system_enabled'=>['type'=>'bool','default'=>true],
        // Phase 2: durable Run + SSE is opt-in until PHP/DB integration acceptance.
        'ai_context_references_v1'=>['type'=>'bool','default'=>true],
        'ai_fast_intent_v1'=>['type'=>'bool','default'=>true],
        'ai_router_v3'=>['type'=>'bool','default'=>true],
        'ai_streaming_v2'=>['type'=>'bool','default'=>false],
        // P2：coach（AI 对话）链路休眠开关。默认 false = 休眠：提交/重试/轮询/SSE/
        // 对话读取/能力执行全部拒绝（503 + error_code=coach_disabled），数据与代码
        // 全部保留；后台发布 coach_enabled=true 即整体回退，无需发版。
        'coach_enabled'=>['type'=>'bool','default'=>false],
        'club_enabled' => ['type' => 'bool', 'default' => true],
        // Phase 1 rollout gates. Default false until device acceptance passes;
        // when off, clients keep the legacy full-state sync write path and the
        // command endpoints answer 503 (never silently mutating data).
        'training_commands' => ['type' => 'bool', 'default' => true],
        'direct_records' => ['type' => 'bool', 'default' => true],
        // Legacy-client compatibility only. The AI-first native UI client always uses its new shell.
        'ai_native_home' => ['type' => 'bool', 'default' => false],
        'minimum_build' => ['type' => 'int', 'default' => 0],
        'latest_build' => ['type' => 'int', 'default' => 0],
        'announcement' => ['type' => 'announcement', 'default' => ['enabled' => false, 'title' => '', 'body' => '']],
        // AI onboarding V2. The content surface is deliberately fixed: copy,
        // labels and tips only. There is no system-prompt, tool or safety field.
        'onboarding_v2_enabled' => ['type' => 'bool', 'default' => true],
        'onboarding_assist_daily_limit' => ['type' => 'int', 'default' => 10],
        'contextual_tips_enabled' => ['type' => 'bool', 'default' => true],
        'onboarding_content_version' => ['type' => 'int', 'default' => 1],
        'onboarding_content' => ['type' => 'onboarding_content', 'default' => [
            'welcome_title' => '今天，想先做什么？',
            'welcome_body' => '选一件小事开始；资料可以慢慢补充，没说的内容会保持未知。',
            'task_labels' => ['plan_create' => '帮我安排训练', 'plan_import' => '整理已有计划', 'meal_log' => '先记录一餐', 'workout_log' => '先记录训练', 'explore' => '先了解一下'],
            'tips' => [],
        ]],
    ];
}

function appConfigDefaults(): array {
    $values = [];
    foreach (appConfigDefinitions() as $key => $definition) $values[$key] = $definition['default'];
    return $values;
}

/** Merge a partial admin form over the current draft so out-of-band gates survive. */
function appConfigDraftMerge(array $current, array $submitted): array {
    return appConfigNormalize(array_replace($current, $submitted));
}

function appConfigNormalize(mixed $input): array {
    if (!is_array($input)) throw new RuntimeException('配置格式不正确。');
    $definitions = appConfigDefinitions();
    foreach (array_keys($input) as $key) if (!isset($definitions[$key])) throw new RuntimeException('存在未知配置项：' . mb_substr((string)$key, 0, 40));
    $out = appConfigDefaults();
    foreach ($definitions as $key => $definition) {
        if (!array_key_exists($key, $input)) continue;
        $value = $input[$key];
        if ($definition['type'] === 'bool') {
            if (!is_bool($value)) throw new RuntimeException($key . ' 必须是布尔值。');
            $out[$key] = $value;
        } elseif ($definition['type'] === 'int') {
            if (!is_int($value) || $value < 0 || $value > 1000000) throw new RuntimeException($key . ' 必须是 0—1000000 的整数。');
            $out[$key] = $value;
        } elseif ($definition['type'] === 'onboarding_content') {
            if (!is_array($value)) throw new RuntimeException('引导内容格式不正确。');
            $allowed = ['welcome_title', 'welcome_body', 'task_labels', 'tips'];
            if (array_diff(array_keys($value), $allowed)) throw new RuntimeException('引导内容包含未知字段；不能注入提示词或工具。');
            $title = trim((string)($value['welcome_title'] ?? ''));
            $body = trim((string)($value['welcome_body'] ?? ''));
            if (mb_strlen($title) > 40 || mb_strlen($body) > 300) throw new RuntimeException('欢迎文案过长。');
            $labels = [];
            $taskKeys = ['plan_create', 'plan_import', 'meal_log', 'workout_log', 'explore'];
            $rawLabels = is_array($value['task_labels'] ?? null) ? $value['task_labels'] : [];
            foreach ($taskKeys as $taskKey) {
                $label = trim((string)($rawLabels[$taskKey] ?? ''));
                if ($label !== '' && mb_strlen($label) > 12) throw new RuntimeException('任务入口文案最多 12 字。');
                $labels[$taskKey] = $label;
            }
            $tips = [];
            foreach ((is_array($value['tips'] ?? null) ? $value['tips'] : []) as $tip) {
                if (!is_array($tip)) continue;
                if (array_diff(array_keys($tip), ['id', 'title', 'body', 'screen'])) continue;
                $id = trim((string)($tip['id'] ?? ''));
                $tipTitle = trim((string)($tip['title'] ?? ''));
                $tipBody = trim((string)($tip['body'] ?? ''));
                $screen = (string)($tip['screen'] ?? '');
                if (!preg_match('/^[a-z0-9._-]{1,40}$/D', $id) || !in_array($screen, ['first_set', 'food_fraction', 'report', 'task_center'], true)) continue;
                if ($tipTitle === '' || $tipBody === '' || mb_strlen($tipTitle) > 30 || mb_strlen($tipBody) > 120) continue;
                $tips[] = ['id' => $id, 'title' => $tipTitle, 'body' => $tipBody, 'screen' => $screen];
                if (count($tips) >= 12) break;
            }
            $out[$key] = ['welcome_title' => $title, 'welcome_body' => $body, 'task_labels' => $labels, 'tips' => $tips];
        } else {
            if (!is_array($value)) throw new RuntimeException('公告格式不正确。');
            $unknown = array_diff(array_keys($value), ['enabled', 'title', 'body']);
            if ($unknown) throw new RuntimeException('公告包含未知字段。');
            $enabled = $value['enabled'] ?? false;
            if (!is_bool($enabled)) throw new RuntimeException('公告开关必须是布尔值。');
            $title = trim((string)($value['title'] ?? ''));
            $body = trim((string)($value['body'] ?? ''));
            if (mb_strlen($title) > 80 || mb_strlen($body) > 600) throw new RuntimeException('公告标题最多 80 字，正文最多 600 字。');
            if ($enabled && ($title === '' || $body === '')) throw new RuntimeException('启用公告时标题和正文不能为空。');
            $out[$key] = ['enabled' => $enabled, 'title' => $title, 'body' => $body];
        }
    }
    if ($out['latest_build'] > 0 && $out['minimum_build'] > $out['latest_build']) throw new RuntimeException('最低兼容构建号不能高于最新构建号。');
    $out['onboarding_assist_daily_limit'] = max(1, min(100, (int)$out['onboarding_assist_daily_limit']));
    return $out;
}

function appConfigRow(PDO $db): ?array {
    $q = $db->query("SELECT draft_json,published_json,draft_version,published_version,updated_at,published_at FROM app_config WHERE config_key='app'");
    $row = $q ? $q->fetch(PDO::FETCH_ASSOC) : false;
    return $row ?: null;
}

function appConfigState(PDO $db): array {
    $row = appConfigRow($db);
    $draft = appConfigDefaults();
    $published = appConfigDefaults();
    if ($row) {
        $decodedDraft = json_decode((string)$row['draft_json'], true);
        if (is_array($decodedDraft)) $draft = appConfigNormalize($decodedDraft);
        if (is_string($row['published_json'])) {
            $decodedPublished = json_decode($row['published_json'], true);
            if (is_array($decodedPublished)) $published = appConfigNormalize($decodedPublished);
        }
    }
    return [
        'draft' => $draft, 'published' => $published,
        'draft_version' => (int)($row['draft_version'] ?? 0),
        'published_version' => (int)($row['published_version'] ?? 0),
        'updated_at' => $row['updated_at'] ?? null,
        'published_at' => $row['published_at'] ?? null,
        'dirty' => $draft !== $published,
    ];
}

/** Serialize version checks with their writes, rather than checking before a lock. */
function appConfigLockedState(PDO $db): array {
    if (!$db->inTransaction()) throw new LogicException('Configuration lock needs a transaction');
    $defaults = json_encode(appConfigDefaults(), JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    $db->prepare("INSERT INTO app_config(config_key,draft_json,updated_at) VALUES('app',?,UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE config_key='app'")->execute([$defaults]);
    $db->query("SELECT config_key FROM app_config WHERE config_key='app' FOR UPDATE")->fetch();
    return appConfigState($db);
}

function appConfigPublished(PDO $db): array {
    $state = appConfigState($db);
    return [
        'version' => $state['published_version'],
        'published_at' => $state['published_at'],
        'config' => $state['published'],
    ];
}

/** Request-local snapshot; daemon workers refresh at job boundaries and at most
 * one second later during long jobs. Keyed by connection, never by user data. */
function appConfigFeatureSnapshot(PDO $db, bool $refresh = false): array {
    static $snapshots;
    $snapshots ??= new WeakMap();
    $now = microtime(true);
    $cached = $snapshots[$db] ?? null;
    if ($refresh || $cached === null || $now - $cached['at'] >= 1.0) {
        $cached = ['at'=>$now, 'published'=>appConfigPublished($db)];
        $snapshots[$db] = $cached;
    }
    return $cached['published'];
}

function appFeatureEnabled(PDO $db, string $key): bool {
    $published = appConfigFeatureSnapshot($db);
    return (bool)($published['config'][$key] ?? false);
}

/**
 * Coach 对话链路是否可用（P2 休眠开关）。
 *
 * 默认（未发布 / 发布值为 false）= 休眠。所有 coach 专属入口都必须先问这一句；
 * 非 coach 的 4 项（生成计划 / 解析计划 / 饮食识别 / 日报 / 周报）不经过任何
 * coach 闸门，因此不受影响。HTTP 调用点用 fail(...,503,'coach_disabled') 拒绝，
 * CLI 调用点（自动跟进 cron、Run worker）用 continue / rejected 结果跳过。
 */
function coachEnabled(PDO $db): bool {
    return appFeatureEnabled($db, 'coach_enabled');
}
