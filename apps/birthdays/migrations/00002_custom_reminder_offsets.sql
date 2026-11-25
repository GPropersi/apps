-- +goose Up
-- Reminder timings widen from {0,1,7} to on the day, 1 day before, and 1 to 52 whole weeks before. The new default is
-- 2 weeks, 1 week and 1 day before. Rollback past this release is forward-fix only: Down fails once any offset other
-- than 0, 1 or 7 is stored, and the previous app version's validator rejects stored values such as 14, so a
-- rolled-back image can fail a settings save with a 400.
ALTER TABLE users ALTER COLUMN default_offsets SET DEFAULT '{14,7,1}';
UPDATE users SET default_offsets = '{14,7,1}' WHERE default_offsets = '{7,1}';
ALTER TABLE reminder_settings DROP CONSTRAINT reminder_settings_offsets_check;
ALTER TABLE reminder_settings ADD CONSTRAINT reminder_settings_offsets_check CHECK (cardinality(offsets) >= 1 AND offsets <@ ARRAY[0,1,7,14,21,28,35,42,49,56,63,70,77,84,91,98,105,112,119,126,133,140,147,154,161,168,175,182,189,196,203,210,217,224,231,238,245,252,259,266,273,280,287,294,301,308,315,322,329,336,343,350,357,364]::smallint[]);

-- +goose Down
-- Down fails once any reminder_settings row holds a week value other than 7. That is accepted: the platform never
-- runs Down on rollback.
ALTER TABLE users ALTER COLUMN default_offsets SET DEFAULT '{7,1}';
ALTER TABLE reminder_settings DROP CONSTRAINT reminder_settings_offsets_check;
ALTER TABLE reminder_settings ADD CONSTRAINT reminder_settings_offsets_check CHECK (cardinality(offsets) >= 1 AND offsets <@ ARRAY[0,1,7]::smallint[]);
