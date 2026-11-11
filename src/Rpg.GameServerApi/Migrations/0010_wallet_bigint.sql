-- Review fix (2026-11-09): balances are 64-bit. With int, a balance near 2^31 made the credit overflow; because the money
-- and the verdict commit in one transaction, the verdict failed on every retry and the run stalled. Deltas stay int (one
-- grant, one pack, one dust move is bounded by its rule); the balances they add up to are bigint.
ALTER TABLE wallets ALTER COLUMN gems TYPE bigint, ALTER COLUMN dust TYPE bigint;
