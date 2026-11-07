-- B1 P1: durable proof that a media version belongs to a committed upload.
-- The upload transaction writes the exact version file name; recovery no longer
-- depends on the seven-day media_upload_events retention window.
ALTER TABLE user_media
    ADD COLUMN version_file VARCHAR(140) NULL AFTER content_type;
