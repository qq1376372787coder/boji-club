<?php
declare(strict_types=1);
require_once __DIR__.'/member-feedback.php';

/**
 * Member data export (synthetic fixtures only in tests).
 *
 * Contains account/profile facts/onboarding sessions/jobs/proposals/commands/
 * memory/conversations and media metadata. No session tokens, AI owner token,
 * APNs keys, Apple identity token, admin notes or other members' rows.
 *
 * PIPL 阶段4（言言①）：`memory_offset` 是**单次分页上限，不是权利总量上限**——
 * 第45条查阅/复制权不受 500 条限制。客户端按 `memory_export.has_more` 连续拉取
 * 直至导完；`memory_export` 给出 total/exported，供界面显示"共 N 条，已导出 M 条"。
 * 其余带固定上限的分区通过 `truncated_sections` 显式披露，不再静默截断。
 */
function accountDataExport(PDO $db, int $uid, int $memoryOffset = 0, int $memoryLimit = 500): array {
    $memoryOffset = max(0, $memoryOffset);
    $memoryLimit = max(1, min(500, $memoryLimit));
    $account = userPayload($db, $uid);
    $facts = profileFactsPublicDocument(profileFactsRead($db, $uid));
    $withdrawals=$db->prepare('SELECT field_name,revision,deleted_at FROM user_profile_tombstones WHERE user_id=?');$withdrawals->execute([$uid]);$withdrawn=$withdrawals->fetchAll(PDO::FETCH_ASSOC);
    $sessions = [];
    $q = $db->prepare('SELECT id,schema_version,revision,task_kind,status,draft_json,conversation_id,first_job_id,first_proposal_id,first_command_id,covenant_version,covenant_accepted_at,created_at,updated_at,deferred_at,completed_at FROM user_onboarding_sessions WHERE user_id=? ORDER BY created_at DESC LIMIT 50');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $row['draft_json'] = json_decode((string)$row['draft_json'], true);
        $sessions[] = $row;
    }
    $onboardingMessages = [];
    $q = $db->prepare('SELECT m.session_id,m.role,m.content,m.created_at FROM user_onboarding_messages m WHERE m.user_id=? ORDER BY m.id LIMIT 500');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $onboardingMessages[] = $row;
    $assistUsage = [];
    $q = $db->prepare('SELECT usage_day,turns FROM onboarding_assist_usage WHERE user_id=? ORDER BY usage_day DESC LIMIT 90');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $assistUsage[] = $row;
    $jobs = [];
    $q = $db->prepare('SELECT client_job_id,kind,purpose,completed_at,created_at FROM ai_user_jobs WHERE user_id=? ORDER BY created_at DESC LIMIT 500');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $jobs[] = $row;
    $proposals = [];
    $q = $db->prepare('SELECT proposal_id,kind,status,expires_at,confirmed_command_id,created_at,updated_at FROM ai_action_proposals WHERE user_id=? ORDER BY created_at DESC LIMIT 200');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $proposals[] = $row;
    $commands = [];
    $q = $db->prepare('SELECT operation_id,actor,command_type,status,after_version,created_at FROM data_operations WHERE user_id=? ORDER BY created_at DESC LIMIT 500');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $commands[] = $row;
    $memory = [];
    $count = $db->prepare('SELECT COUNT(*) FROM user_memory_items WHERE user_id=?');
    $count->execute([$uid]);
    $memoryTotal = (int)$count->fetchColumn();
    // 整数直接内插（已 cast），避免 PDO 在部分驱动下把 LIMIT 绑定当字符串。
    $q = $db->prepare('SELECT memory_id,kind,status,origin,content,confidence,evidence_json,created_at,updated_at FROM user_memory_items WHERE user_id=? ORDER BY created_at DESC, memory_id DESC LIMIT ' . $memoryLimit . ' OFFSET ' . $memoryOffset);
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $row['evidence_refs'] = json_decode((string)$row['evidence_json'], true);
        unset($row['evidence_json']);
        $memory[] = $row;
    }
    $conversations = [];
    $q = $db->prepare('SELECT conversation_id,created_at,updated_at FROM ai_conversations WHERE user_id=? ORDER BY updated_at DESC LIMIT 100');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $conversation) {
        $messages = [];
        $m = $db->prepare('SELECT role,content,created_at FROM ai_messages WHERE user_id=? AND conversation_row_id=(SELECT id FROM ai_conversations WHERE user_id=? AND conversation_id=?) ORDER BY id LIMIT 1000');
        $m->execute([$uid, $uid, $conversation['conversation_id']]);
        foreach ($m->fetchAll(PDO::FETCH_ASSOC) as $row) $messages[] = $row;
        $conversations[] = $conversation + ['messages' => $messages];
    }
    $media = [];
    $q = $db->prepare('SELECT media_id,byte_size,content_type,created_at,updated_at FROM user_media WHERE user_id=? ORDER BY created_at DESC LIMIT 2000');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $media[] = $row;
    $runs = [];
    $q = $db->prepare('SELECT id,status,error_code,created_at,updated_at FROM ai_runs WHERE user_id=? ORDER BY created_at DESC LIMIT 200');
    $q->execute([$uid]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) $runs[] = $row;
    // 言言①：memory 已分页；其余带固定上限的分区**显式披露**，不再静默截断。
    // 表名来自本文件硬编码白名单，非用户输入，无注入面。
    $truncated = [];
    foreach ([
        'onboarding_sessions' => ['user_onboarding_sessions', 50],
        'onboarding_messages' => ['user_onboarding_messages', 500],
        'onboarding_assist_usage' => ['onboarding_assist_usage', 90],
        'ai_jobs' => ['ai_user_jobs', 500],
        'proposals' => ['ai_action_proposals', 200],
        'commands' => ['data_operations', 500],
        'conversations' => ['ai_conversations', 100],
        'media_metadata' => ['user_media', 2000],
        'ai_runs' => ['ai_runs', 200],
    ] as $section => [$table, $limit]) {
        $probe = $db->prepare('SELECT COUNT(*) FROM ' . $table . ' WHERE user_id=?');
        $probe->execute([$uid]);
        $total = (int)$probe->fetchColumn();
        if ($total > $limit) $truncated[$section] = ['total' => $total, 'exported' => $limit];
    }
    return [
        'member_feedback' => feedbackExport128($db,$uid),
        'schema_version' => 1,
        'exported_at' => gmdate('c'),
        'account' => $account,
        'profile_facts' => $facts, 'profile_withdrawals'=>$withdrawn,
        'onboarding_sessions' => $sessions,
        'onboarding_messages' => $onboardingMessages,
        'onboarding_assist_usage' => $assistUsage,
        'ai_jobs' => $jobs,
        'proposals' => $proposals,
        'commands' => $commands,
        'memory_items' => $memory,
        'memory_export' => [
            'total' => $memoryTotal,
            'exported' => count($memory),
            'offset' => $memoryOffset,
            'page_size' => $memoryLimit,
            'has_more' => $memoryOffset + count($memory) < $memoryTotal,
        ],
        'truncated_sections' => $truncated,
        'conversations' => $conversations,
        'ai_runs' => $runs,
        'media_metadata' => $media,
        'note' => '媒体文件本体需通过对应记录逐张导出；本文件只含元数据，不含密钥、登录令牌或他人的数据。',
    ];
}
