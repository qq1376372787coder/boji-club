-- PIPL 阶段4（2026-11-08，言言定性回执 ③）：学习与使用拆成两个独立开关。
--
--   proactive_learning      停止学习      = 第15条撤回同意的最小形态：
--                                           立即停止写入新记忆，存量保留。
--   personalization_enabled 停用AI记忆处理 = 第44/46条限制处理：
--                                           存量可保留，但不再喂给模型做个性化。
--
-- 两者都必须前瞻性即时生效，且关闭不得拒绝核心记录功能（第16条）。
-- 默认 TRUE 保持既有用户行为不变；关闭是显式动作，不是缺省。
ALTER TABLE user_action_preferences
  ADD COLUMN IF NOT EXISTS personalization_enabled BOOLEAN NOT NULL DEFAULT TRUE AFTER proactive_learning;
