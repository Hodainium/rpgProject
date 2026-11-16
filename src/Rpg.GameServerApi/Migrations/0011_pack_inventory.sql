-- Spec pack-shop (slice 5b0) 3.2: packs are bought, owned unopened, and opened one at a time. Both tables are written only in
-- the account transaction under acct:<player>, so a buy and an open of one player never interleave; the count always equals
-- the ledger's sum for (player, pack). Nobody owns a pack before this slice, so nothing is migrated.
CREATE TABLE pack_inventory (
  player_id uuid NOT NULL REFERENCES players(player_id),
  pack_id text NOT NULL,
  count int NOT NULL CHECK (count >= 0),
  updated_at timestamptz NOT NULL,
  -- Spec pack-shop 2.5: a refund held for a support check (packs no buy row prices); logins skip it until operations clears it.
  refund_held boolean NOT NULL DEFAULT false,
  PRIMARY KEY (player_id, pack_id));

CREATE TABLE pack_ledger (                      -- append-only: +n per buy, -1 per open, -n per refund
  id bigserial PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players(player_id),
  pack_id text NOT NULL,
  pack_version int NOT NULL,
  delta int NOT NULL CHECK (delta <> 0),
  reason text NOT NULL CHECK (reason IN ('buy','open','refund')),
  request_key uuid NOT NULL,
  opening_id uuid NULL,
  created_at timestamptz NOT NULL);
CREATE INDEX pack_ledger_player ON pack_ledger (player_id, created_at);
-- One row per account request and reason: a buy, an open or a refund applied twice is refused by the database, not only by
-- the request log. The reason is part of the key so a player's own request key can never take a refund's derived key.
CREATE UNIQUE INDEX pack_ledger_request ON pack_ledger (player_id, reason, request_key);

-- Spec pack-shop 2.5: a retired version can refund every unopened pack (and then skips the openability rule).
ALTER TABLE pack_types ADD COLUMN refund_unopened boolean NOT NULL DEFAULT false;

-- The buy is a new kind of account request (its own kind, so a buy key replayed as an open is a 1407).
ALTER TABLE account_requests DROP CONSTRAINT account_requests_kind_check;
ALTER TABLE account_requests ADD CONSTRAINT account_requests_kind_check CHECK (kind IN ('pack','dust','craft','pack_buy'));
