select (select status from runs) = 'Rejected' and (select ended_at from runs) is not null and (select verified_seq from runs) = 0
select (select genesis_hash from runs) is not null and (select genesis_hash from runs) <> repeat('f', 64)
select count(*) = 1 from run_steps where kind = 'genesis' and status = 'Verified'
select count(*) = 0 from run_steps where kind <> 'genesis' and status in ('Verified', 'Rejected')
select count(*) = 1 from outbox where type = 'RunRolledBack' and (payload->'payload'->>'terminal')::boolean and payload->'payload'->>'reason' = 'GenesisMismatch'
select count(*) = 1 from outbox where type = 'AntiCheatAlert'
select count(*) = 0 from wallet_ledger where status <> 'voided'
select count(*) = 0 from completion_marks
