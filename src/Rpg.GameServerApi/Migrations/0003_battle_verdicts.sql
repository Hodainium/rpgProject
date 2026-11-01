-- Spec battle-verify 3.2: the verifier's verdict on a battle session, and the bookkeeping for jobs.
ALTER TABLE battle_sessions
  ADD COLUMN verdict jsonb,                       -- BattleVerdict; set together with status Verified/Rejected
  ADD COLUMN verified_at timestamptz,
  ADD COLUMN verifier_version text,               -- the worker's ruleset version
  ADD COLUMN attempts int NOT NULL DEFAULT 0,     -- runner errors, plus the verdict itself
  ADD COLUMN enqueued_at timestamptz,             -- last confirmed publish of a verify job
  ADD COLUMN dead_lettered_at timestamptz,
  ADD COLUMN dead_letter_reason text;

ALTER TABLE battle_sessions ADD CONSTRAINT battle_sessions_status
  CHECK (status IN ('Submitted', 'Verified', 'Rejected'));
ALTER TABLE battle_sessions ADD CONSTRAINT battle_sessions_verdict_set
  CHECK ((status = 'Submitted') = (verdict IS NULL));

CREATE INDEX battle_sessions_pending ON battle_sessions (submitted_at)
  WHERE status = 'Submitted' AND dead_lettered_at IS NULL;
