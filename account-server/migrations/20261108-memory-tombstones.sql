-- PIPL 阶段4（2026-11-08，言言定性回执 ②）：删除权 = 本体 + 派生全链路物理清除。
--
-- 问题：只 DELETE user_memory_items 会在下一次 aiMemoryExtract 时按同一
--       idempotency_key 重新 INSERT，被删除的记忆**复活**，第47条删除权形同虚设。
-- 方案：墓碑表只存 (user_id, idempotency_key, kind, deleted_at)——纯哈希键，
--       不含任何正文/证据（正文随本体一并物理删除），但永久阻止同一来源重新学习。
-- 派生物：本库无向量/嵌入/摘要缓存；洞察由已核验任务与确认训练日计算（不读记忆），
--         prompt 上下文与导出均为活读——删本体即同时清空，无需额外清理任务。
CREATE TABLE IF NOT EXISTS user_memory_tombstones (
 user_id BIGINT UNSIGNED NOT NULL, idempotency_key CHAR(64) NOT NULL, kind VARCHAR(16) NOT NULL,
 deleted_at DATETIME NOT NULL,
 PRIMARY KEY (user_id, idempotency_key), INDEX user_memory_tombstones_user (user_id, deleted_at),
 CONSTRAINT user_memory_tombstones_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
