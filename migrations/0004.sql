ALTER TABLE baselines ADD COLUMN canonical_path BLOB;
ALTER TABLE remote_observations ADD COLUMN canonical_path BLOB;
ALTER TABLE plans ADD COLUMN canonical_path BLOB;
ALTER TABLE conflicts ADD COLUMN canonical_path BLOB;

DELETE FROM remote_observations;
DELETE FROM remote_inventory;
