-- Preserve existing operators: before this migration every admin had full access.
ALTER TABLE admin_accounts
  ADD COLUMN role ENUM('super_admin','operator','content','support','readonly') NOT NULL DEFAULT 'readonly' AFTER password_hash,
  ADD COLUMN status ENUM('active','disabled') NOT NULL DEFAULT 'active' AFTER role;
UPDATE admin_accounts SET role='super_admin' WHERE role='readonly';
