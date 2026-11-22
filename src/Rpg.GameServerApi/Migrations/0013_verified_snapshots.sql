-- Spec hash-id-lists 4 (H12): the verifier's own state at a checkpoint. A verified step writes the snapshot its replay reached
-- at to_seq beside the client's claim (`snapshot`, kept as claimed). The next step starts from it and GET /resume serves it,
-- like step 1 starts from the server's genesis snapshot: a forged or corrupted claim (its own hash is not the claimed state
-- hash, so the step starting from it is rejected) is never the state a rolled-back run is rebuilt from. NULL until the step
-- ending at that seq is verified (and for runs verified before 0013).
ALTER TABLE run_actions ADD COLUMN verified_snapshot jsonb;

-- A rollback archives the verifier's state with the claim, so an audit can compare the two (review fix).
ALTER TABLE run_actions_voided ADD COLUMN verified_snapshot jsonb;
