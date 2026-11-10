-- Phase 2: capability registry routing (spec §2/§3) + action undo (spec §2).
-- Expand-only: new proposal kinds are additive to the enum; undo_json is NULL
-- for every pre-existing row. Rollback = stop using the new kinds/endpoints.

-- 1. Proposal kinds for the capability router (single-occurrence exercise swap
--    and candidate plan activation).
ALTER TABLE ai_action_proposals
  MODIFY COLUMN kind ENUM('meal_draft','weight_entry','plan_change_proposal','exercise_swap','plan_activation') NOT NULL;

-- 2. Inverse payload for action.undo (direct records only, bounded window).
ALTER TABLE data_operations ADD COLUMN IF NOT EXISTS undo_json MEDIUMTEXT NULL AFTER diff_json;
