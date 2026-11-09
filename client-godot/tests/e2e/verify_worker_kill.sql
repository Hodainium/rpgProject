select count(*) >= 2 from battle_sessions
select bool_and(status = 'Verified' and verdict is not null) from battle_sessions
select count(*) = count(distinct battle_id) from battle_sessions
select bool_and(attempts = 1 and dead_lettered_at is null) from battle_sessions
select bool_and(status = 'Verified') and count(*) = count(distinct (epoch, step_no)) from run_steps
select (select status from runs) in ('Won', 'Lost') and (select epoch from runs) = 0
select (select gems from wallets) = 10 * (select count(*) from completion_marks) and (select count(*) from completion_marks) >= 2
select count(*) = count(distinct idempotency_key) from wallet_ledger
select bool_and(status = 'released') from wallet_ledger
select count(*) = (select count(*) from completion_marks) from outbox where type = 'RewardGranted'
select count(*) = 0 from outbox where type in ('RunRolledBack', 'AntiCheatAlert')
