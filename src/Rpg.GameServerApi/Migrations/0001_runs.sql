-- Spec server-authority 3.4, Part A: players, runs and their floor seeds. Postgres is the source of truth.
CREATE TABLE players (
  player_id uuid PRIMARY KEY,
  display_name text NOT NULL,
  created_at timestamptz NOT NULL);

CREATE TABLE runs (
  run_id uuid PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  ruleset_version text NOT NULL,
  run_structure_id text NOT NULL,
  character_ids text[] NOT NULL,
  status text NOT NULL,
  current_floor int NOT NULL DEFAULT 0,
  last_seq int NOT NULL DEFAULT 0,
  claimed_run_hash text,
  started_at timestamptz NOT NULL,
  ended_at timestamptz);

-- At most one run a player can still play or is waiting on.
CREATE UNIQUE INDEX one_active_run ON runs (player_id) WHERE status IN ('Active', 'Verifying');

CREATE TABLE run_floors (
  run_id uuid NOT NULL REFERENCES runs,
  floor int NOT NULL,
  floor_seed bigint NOT NULL CHECK (floor_seed >= 0),
  issued_at timestamptz NOT NULL,
  PRIMARY KEY (run_id, floor));
