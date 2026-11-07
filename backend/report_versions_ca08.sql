-- CA-08 / B04 report version chain (SQLite job store: /opt/bojiclub-ai/.data/jobs.sqlite3)
-- server.py adds these columns idempotently at startup. This file is the
-- manual migration/rollback reference requested by the handoff (previously the
-- code comment named a file that was not shipped).
--
-- Semantics:
--   parent_id        job_id of the previous version for the same owner/kind/date
--   source_revision  source fingerprint submitted with the request
--   source_status    'current' | 'stale'; NULL in legacy rows is treated as current
--   source_note      human-readable reason when a report became stale
--
-- Forward (safe to re-run; use the sqlite3 CLI):
--   sqlite3 /opt/bojiclub-ai/.data/jobs.sqlite3 < report_versions_ca08.sql
--
-- Rollback (only after exporting report_archive; older code ignores the columns):
--   DROP INDEX IF EXISTS reports_parent;
--   DROP INDEX IF EXISTS reports_source;
--   ALTER TABLE report_archive DROP COLUMN parent_id;
--   ALTER TABLE report_archive DROP COLUMN source_revision;
--   ALTER TABLE report_archive DROP COLUMN source_status;
--   ALTER TABLE report_archive DROP COLUMN source_note;

ALTER TABLE report_archive ADD COLUMN parent_id TEXT;
ALTER TABLE report_archive ADD COLUMN source_revision TEXT;
ALTER TABLE report_archive ADD COLUMN source_status TEXT;
ALTER TABLE report_archive ADD COLUMN source_note TEXT;
CREATE INDEX IF NOT EXISTS reports_parent ON report_archive(parent_id);
CREATE INDEX IF NOT EXISTS reports_source ON report_archive(owner,kind,date,source_status);
