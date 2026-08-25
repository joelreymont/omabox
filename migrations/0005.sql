-- Version four inventories encoded directories as unsupported observations.
-- Discard the remote snapshot and cursor so the next refresh republishes a
-- complete inventory with first-class directory observations.
DELETE FROM remote_observations;
DELETE FROM remote_inventory;

PRAGMA user_version = 5;
