select (select epoch from runs) = 1 and (select rollbacks from runs) = 1 and (select status from runs) = 'Won'
select count(*) = 1 from run_steps where verdict->'mismatch'->>'reason' = 'ConditionsMismatch'
select count(*) = 1 from outbox where type = 'RunRolledBack' and payload->'payload'->>'reason' = 'ConditionsMismatch'
select count(*) = 1 from outbox where type = 'AntiCheatAlert'
select count(*) = 1 from battle_sessions_voided where status = 'Submitted'
select count(*) = 0 from battle_sessions where status = 'Rejected'
select (select verified_seq from runs) = (select end_seq from runs)
select count(*) = 0 from wallet_ledger where status = 'pending'
select count(*) = (select count(*) from outbox where type = 'RewardVoided') from wallet_ledger where status = 'voided'
select (select coalesce(sum(gems), 0) from wallets) = (select coalesce(sum(delta), 0) from wallet_ledger where status = 'released')
select (select count(*) from completion_marks) = (select count(*) from wallet_ledger where status = 'released')
select count(*) = 1 from outbox where type = 'RunVerified'
