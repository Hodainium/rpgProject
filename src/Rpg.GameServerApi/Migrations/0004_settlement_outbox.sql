-- Spec settlement-outbox 3.2: the transactional outbox, the gem wallet with its append-only ledger, and completion marks.
CREATE TABLE outbox (
  id uuid PRIMARY KEY,                       -- event id; also the Kafka event-id header and the RabbitMQ message-id
  seq bigint GENERATED ALWAYS AS IDENTITY,   -- relay order (a uuid is not ordered)
  destination text NOT NULL CHECK (destination IN ('rabbit','redpanda')),
  topic text NOT NULL,                       -- RabbitMQ routing key or Redpanda topic
  key text NOT NULL,                         -- battleId (rabbit) or playerId (redpanda): the ordering scope
  type text NOT NULL,
  payload jsonb NOT NULL,
  traceparent text,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  leased_until timestamptz,
  attempts int NOT NULL DEFAULT 0,
  dead_lettered_at timestamptz,
  dead_letter_reason text);
CREATE INDEX outbox_unpublished ON outbox (seq) WHERE published_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX outbox_key ON outbox (destination, key, seq) WHERE published_at IS NULL AND dead_lettered_at IS NULL;

CREATE TABLE wallets (
  player_id uuid PRIMARY KEY REFERENCES players,
  gems int NOT NULL DEFAULT 0 CHECK (gems >= 0),
  version bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE wallet_ledger (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  currency text NOT NULL CHECK (currency IN ('gems')),
  delta int NOT NULL CHECK (delta <> 0),
  reason text NOT NULL,
  ref_battle_id text,
  idempotency_key text NOT NULL UNIQUE,      -- 'mark:{battleId}:{characterId}:{bossId}': the exactly-once key
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX wallet_ledger_player ON wallet_ledger (player_id, id DESC);

CREATE TABLE completion_marks (
  player_id uuid NOT NULL REFERENCES players,
  character_id text NOT NULL,
  boss_id text NOT NULL,
  battle_id text NOT NULL REFERENCES battle_sessions,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, character_id, boss_id));  -- a character's first win over a boss pays once, ever

-- The sweeper retires: a session still waiting for a verdict gets its job as an outbox row, unless the old publisher put a
-- job on the queue lately (enqueued within RepublishAfter, 10 minutes): that one is still queued or being replayed.
INSERT INTO outbox (id, destination, topic, key, type, payload)
SELECT gen_random_uuid(), 'rabbit', 'battle', battle_id, 'VerifyBattleJob',
       jsonb_build_object('battleId', battle_id, 'runId', run_id, 'runSeq', run_seq,
                          'rulesetVersion', ruleset_version, 'submittedAt', to_jsonb(submitted_at))
FROM battle_sessions
WHERE status = 'Submitted' AND dead_lettered_at IS NULL
  AND (enqueued_at IS NULL OR enqueued_at < now() - interval '10 minutes');

ALTER TABLE battle_sessions DROP COLUMN enqueued_at;
