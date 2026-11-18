-- Spec account-session (slice 5b1) 3.1: the player's account session, a fencing token. POST /account/session raises it under
-- the account lock acct:<player>; every account-changing call carries it and is refused (409 1412) when it is not the current
-- one. 0 = no session started yet (the first session is 1), so every existing player starts with no session and the next
-- login starts one.
ALTER TABLE players ADD COLUMN account_session bigint NOT NULL DEFAULT 0;

-- The account version: raised by every change to what the collection shows (gems, dust, cards, packs and their refund holds,
-- pity), by any writer. Named for what it is (it was wallets.version: the column lives in wallets because gems were stored
-- there first). Account decisions carry the account version the screen showed (409 1413 when it moved).
ALTER TABLE wallets RENAME COLUMN version TO account_version;
