-- Spec run-verify 3.2: steps, the verified prefix, the epoch, the genesis anchor, voided archives and pending gems.

ALTER TABLE runs
  ADD COLUMN epoch int NOT NULL DEFAULT 0,          -- bumped by every rollback
  ADD COLUMN verified_seq int NOT NULL DEFAULT 0,   -- the verified prefix: 0 until the client's seq 1 matches the anchor, then always a checkpoint seq
  ADD COLUMN end_seq int,                           -- the end action's seq once a win is submitted
  ADD COLUMN rollbacks int NOT NULL DEFAULT 0,
  ADD COLUMN rollback_reason text,                  -- the coarse category told to a client with a stale epoch (1108)
  ADD COLUMN genesis_hash text,                     -- the server's anchor: run_hash() of the state rebuilt at run start
  ADD COLUMN genesis_snapshot jsonb,                -- that state, opaque JSON: served by /resume for seq 1 and for a run with no uploads
  ADD COLUMN legacy boolean NOT NULL DEFAULT false; -- started before this migration: never verified, no steps, no gate
-- Every run that exists now was started without a genesis step: it stays as slice 2b left it.
UPDATE runs SET legacy = true;

ALTER TABLE run_floors
  ADD COLUMN end_seq int,                           -- seq of the next_floor action that left it (set at upload)
  ADD COLUMN verified_at timestamptz,
  ADD COLUMN digest jsonb;                          -- the floor read model's source

CREATE TABLE run_steps (
  run_id uuid NOT NULL REFERENCES runs, epoch int NOT NULL, step_no int NOT NULL,
  from_seq int NOT NULL, to_seq int NOT NULL CHECK (to_seq > from_seq),
  kind text NOT NULL CHECK (kind IN ('genesis','segment','battle','end')),
  status text NOT NULL CHECK (status IN ('Pending','Verified','Rejected','Voided')),
  verdict jsonb, start_hash text, end_hash text,
  attempts int NOT NULL DEFAULT 0, dead_lettered_at timestamptz, dead_letter_reason text,
  created_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz,
  PRIMARY KEY (run_id, epoch, step_no),
  CONSTRAINT run_steps_verdict_set CHECK (status NOT IN ('Verified','Rejected') OR verdict IS NOT NULL));
CREATE INDEX run_steps_pending ON run_steps (created_at) WHERE status = 'Pending' AND dead_lettered_at IS NULL;
CREATE INDEX run_steps_by_seq ON run_steps (run_id, epoch, to_seq);

CREATE TABLE run_actions_voided (LIKE run_actions, epoch int NOT NULL, voided_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, epoch, seq));
CREATE TABLE battle_sessions_voided (LIKE battle_sessions, epoch int NOT NULL, voided_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (battle_id, epoch));          -- LIKE copies no foreign key: the live row is deleted

-- Pending gems (spec run-verify 2.5). Existing rows were settled by slice 4: released.
ALTER TABLE wallet_ledger
  ADD COLUMN status text NOT NULL DEFAULT 'released' CHECK (status IN ('pending','released','voided')),
  ADD COLUMN released_at timestamptz,
  ADD COLUMN character_id text;             -- who earned it: a void frees that character's completion mark
UPDATE wallet_ledger SET released_at = created_at;
CREATE INDEX wallet_ledger_pending ON wallet_ledger (ref_battle_id) WHERE status = 'pending';
