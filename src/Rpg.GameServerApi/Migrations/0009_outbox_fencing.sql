-- Spec settlement-outbox 2.1 (review fix, 2026-11-09): lease fencing. Each lease call stamps its rows with a token; every
-- follow-up write (renew, published, retry, release, dead letter) only touches a row that still carries the caller's token,
-- so a relay whose lease ran out can neither publish nor update a row another relay now holds.
-- (The per-key commit order is kept by advisory locks, not a column: OutboxWriter and OutboxStore.LeaseAsync.)
ALTER TABLE outbox ADD COLUMN lease_token uuid;
