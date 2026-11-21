select (select epoch from runs) = 1 and (select rollbacks from runs) = 1
select count(*) = 1 from run_steps where verdict->'mismatch'->>'reason' = 'ConditionsMismatch'
select count(*) = 1 from outbox where type = 'RunRolledBack' and payload->'payload'->>'reason' = 'ConditionsMismatch'
select count(*) = 1 from outbox where type = 'AntiCheatAlert'
select count(*) >= 1 from battle_sessions_voided where battle_id ~ '/w2$'
select count(*) = 0 from battle_sessions where status = 'Rejected'
select count(*) = 0 from wallet_ledger where status = 'released'
