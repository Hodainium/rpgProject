-- Spec server-authority 3.4, Part B: a run's ordered action log (claimed snapshots at checkpoints) and its battles.
CREATE TABLE run_actions (
  run_id uuid NOT NULL REFERENCES runs,
  seq int NOT NULL,
  floor int NOT NULL,
  type text NOT NULL,
  action jsonb NOT NULL,      -- the RunAction as sent, without its battle (that lives in battle_sessions)
  state_hash text NOT NULL,
  snapshot jsonb,             -- checkpoint actions only
  played_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (run_id, seq));

CREATE INDEX run_actions_checkpoints ON run_actions (run_id, seq) WHERE snapshot IS NOT NULL;

CREATE TABLE battle_sessions (
  battle_id text PRIMARY KEY,
  run_id uuid NOT NULL,
  run_seq int NOT NULL,
  seed bigint NOT NULL CHECK (seed >= 0),
  ruleset_version text NOT NULL,
  conditions jsonb NOT NULL,  -- as played; verified in slice 3
  action_log jsonb NOT NULL,
  status text NOT NULL,
  submitted_at timestamptz NOT NULL,
  UNIQUE (run_id, run_seq),
  FOREIGN KEY (run_id, run_seq) REFERENCES run_actions);
