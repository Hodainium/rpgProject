-- Spec economy-challenges 3.2: a reward belongs to a challenge, paid once per cycle.

-- reward_rules: the challenge id replaces (kind, id); every 4c rule was a boss rule, so it moves to its derived id boss/<id>.
ALTER TABLE reward_rules RENAME COLUMN source_id TO challenge_id;
UPDATE reward_rules SET challenge_id = 'boss/' || challenge_id;
ALTER TABLE reward_rules DROP COLUMN source_kind;   -- drops its check, its unique key and the latest index with it
ALTER TABLE reward_rules
  ADD COLUMN cycle text NOT NULL DEFAULT 'once' CHECK (cycle IN ('once', 'weekly')),
  ADD COLUMN ends_at timestamptz,                    -- null = never expires
  ADD UNIQUE (challenge_id, version);
CREATE INDEX reward_rules_latest ON reward_rules (challenge_id, version DESC);

CREATE TABLE reward_cycle_resets (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  challenge_id text NOT NULL,
  player_id uuid REFERENCES players,                 -- null = a reset for everyone
  generation int NOT NULL CHECK (generation >= 1),   -- counted per scope: (challenge, everyone) or (challenge, player)
  reset_by text NOT NULL,
  reason text,
  reset_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX reward_cycle_resets_scope ON reward_cycle_resets
  (challenge_id, COALESCE(player_id, '00000000-0000-0000-0000-000000000000'::uuid), generation);

-- completion_marks: one row per (player, character, challenge, cycle). Its existence means "paid for this cycle".
ALTER TABLE completion_marks RENAME COLUMN boss_id TO challenge_id;
UPDATE completion_marks SET challenge_id = 'boss/' || challenge_id;
ALTER TABLE completion_marks ADD COLUMN cycle_key text NOT NULL DEFAULT 'once';   -- existing rows: the 'once' cycle
ALTER TABLE completion_marks DROP CONSTRAINT completion_marks_pkey,
  ADD PRIMARY KEY (player_id, character_id, challenge_id, cycle_key);

-- wallet_ledger: source_kind/source_id (4c) become challenge_id; cycle_key is new. Older rows stay null.
ALTER TABLE wallet_ledger RENAME COLUMN source_id TO challenge_id;
UPDATE wallet_ledger SET challenge_id = 'boss/' || challenge_id WHERE challenge_id IS NOT NULL;
ALTER TABLE wallet_ledger DROP COLUMN source_kind, ADD COLUMN cycle_key text;
