-- Spec card-collection 3.2: the card catalog, the account's holdings (a set: owned once), the card ledger, dust as a second
-- currency in the wallet, versioned pack types and card rates, pack pity counters, pack openings with their RNG seed, the
-- request log that makes the account actions idempotent, and the pool a run was started with.

CREATE TABLE catalog_versions (
  catalog_version int PRIMARY KEY,
  catalog_hash text NOT NULL,
  document jsonb NOT NULL,                    -- the whole catalog at that version, so an opening can be re-derived exactly
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE cards (
  card_id text PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('character','item')),
  rarity text NOT NULL CHECK (rarity IN ('common','rare','epic','legendary','mythic')),
  set_id text NOT NULL,
  core boolean NOT NULL DEFAULT false,
  pools text[] NOT NULL DEFAULT '{}',
  retired boolean NOT NULL DEFAULT false,
  catalog_version int NOT NULL);

CREATE TABLE card_holdings (
  player_id uuid NOT NULL REFERENCES players,
  card_id text NOT NULL REFERENCES cards,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL CHECK (source IN ('pack','craft')),
  PRIMARY KEY (player_id, card_id));          -- a set: owned once

CREATE TABLE card_ledger (                    -- append-only; holdings must equal its sum per (player, card)
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  card_id text NOT NULL REFERENCES cards,
  delta smallint NOT NULL CHECK (delta IN (1,-1)),
  reason text NOT NULL CHECK (reason IN ('pack','craft','dust')),
  ref_id text,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX card_ledger_player ON card_ledger (player_id, id DESC);

ALTER TABLE wallets ADD COLUMN dust int NOT NULL DEFAULT 0 CHECK (dust >= 0);
ALTER TABLE wallet_ledger DROP CONSTRAINT wallet_ledger_currency_check;
ALTER TABLE wallet_ledger ADD CONSTRAINT wallet_ledger_currency_check CHECK (currency IN ('gems','dust'));
ALTER TABLE wallet_ledger ADD COLUMN rule_ref text;          -- 'pack:{id}:{v}' or 'rate:{rarity}:{v}' (rule_version stays for rewards)

CREATE TABLE pack_types (
  pack_id text NOT NULL, version int NOT NULL,
  name text NOT NULL,
  price_gems int NOT NULL CHECK (price_gems > 0),
  card_count int NOT NULL CHECK (card_count BETWEEN 1 AND 20),
  odds jsonb NOT NULL,                        -- rarity -> weight per 10000, sums to 10000
  set_ids text[] NOT NULL,
  retired boolean NOT NULL DEFAULT false,
  pity jsonb NOT NULL DEFAULT '{}',           -- rarity -> N: the Nth pack since that rarity last dropped holds one
  first_guarantees jsonb NOT NULL DEFAULT '{}',  -- rarity -> within N packs of a player's first open of the pack type
  min_rarity text,                            -- every pack holds a card of at least this rarity
  effective_from timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,
  PRIMARY KEY (pack_id, version));

CREATE TABLE card_rates (
  rarity text NOT NULL, version int NOT NULL,
  dust_value int NOT NULL CHECK (dust_value > 0),
  craft_cost int NOT NULL,
  effective_from timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,
  PRIMARY KEY (rarity, version),
  CHECK (craft_cost > dust_value));

CREATE TABLE pack_pity (
  player_id uuid NOT NULL REFERENCES players, pack_id text NOT NULL, rarity text NOT NULL,
  missed int NOT NULL CHECK (missed >= 0),
  PRIMARY KEY (player_id, pack_id, rarity));  -- a row appears at a player's first open of the pack type

CREATE TABLE pack_openings (
  opening_id uuid PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  pack_id text NOT NULL, pack_version int NOT NULL, catalog_version int NOT NULL,
  draw_seed bigint NOT NULL,
  pity_before jsonb NOT NULL,                 -- the counters the draw used, so the opening is reproducible
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX pack_openings_player ON pack_openings (player_id, created_at DESC);

CREATE TABLE account_requests (
  player_id uuid NOT NULL REFERENCES players, request_key uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('pack','dust','craft')),
  request_hash text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, request_key));

-- The pool a run was started with (null = the card system was off for this run). Written at run start, never updated.
ALTER TABLE runs ADD COLUMN card_pool jsonb, ADD COLUMN unlocked_characters jsonb;
