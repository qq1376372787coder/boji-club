-- Additive migration. Back up the table/schema before running; no rows removed.
ALTER TABLE ai_user_jobs MODIFY COLUMN kind ENUM('generate_plan','parse_plan','food','report','weekly_review','coach') NOT NULL;
