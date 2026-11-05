-- Spec economy-rewards 3.2: reward rules are server-owned economy data, versioned and append-only.
CREATE TABLE reward_rules (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_kind text NOT NULL CHECK (source_kind IN ('boss')),
  source_id text NOT NULL CHECK (source_id <> '' AND source_id !~ '[:\s]'),   -- no ':' (ledger keys) and no whitespace
  currency text NOT NULL CHECK (currency IN ('gems')),
  amount int NOT NULL CHECK (amount >= 0),                                      -- 0 retires the rule
  version int NOT NULL CHECK (version >= 1),
  effective_from timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_kind, source_id, version));
CREATE INDEX reward_rules_latest ON reward_rules (source_kind, source_id, version DESC);

-- Why a ledger row paid what it paid. Null on rows written before this slice (paid by the flat Settlement:GemsPerBossMark).
ALTER TABLE wallet_ledger
  ADD COLUMN source_kind text,
  ADD COLUMN source_id text,
  ADD COLUMN rule_version int;
