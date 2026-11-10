-- A purchase id is unique to its store transaction, not to one Boji account.
-- The old global UNIQUE made ON DUPLICATE KEY UPDATE able to overwrite another
-- member's entitlement row when the same purchase id appeared across accounts.
ALTER TABLE membership_entitlements
  DROP INDEX last_transaction_id,
  ADD INDEX membership_entitlements_transaction (last_transaction_id);
