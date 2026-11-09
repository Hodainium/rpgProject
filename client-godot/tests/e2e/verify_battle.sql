select count(*) >= 2 from battle_sessions
select bool_and(status = 'Verified' and verdict is not null and verified_at is not null) from battle_sessions
select bool_and(verdict->>'status' = 'Verified' and verdict->>'errorCode' is null and verdict->'mismatch' = 'null'::jsonb) from battle_sessions
select bool_and(verdict->>'finalStateHash' = action_log->>'claimedFinalHash') from battle_sessions
select bool_and(verdict->>'outcome' = action_log->>'claimedOutcome') from battle_sessions
select bool_and(verdict->>'verifierRulesetVersion' = ruleset_version and verifier_version = ruleset_version) from battle_sessions
select bool_and(attempts = 1 and dead_lettered_at is null) from battle_sessions
select count(*) = (select count(*) from run_actions where type = 'battle') from battle_sessions
select count(*) = 0 from outbox where type = 'VerifyBattleJob'
select count(*) > 4 and bool_and(status = 'Verified' and verdict is not null) from run_steps
select count(*) = 1 from run_steps where kind = 'genesis' and step_no = 0
select count(*) = 1 from run_steps where kind = 'end'
select count(*) = (select count(*) from run_steps where kind = 'battle') from battle_sessions
select count(*) = (select count(*) from run_steps) from outbox where type = 'VerifyStepJob' and destination = 'rabbit' and published_at is not null
select (select genesis_hash from runs) is not null and (select genesis_snapshot from runs) is not null
select (select status from runs) = 'Won' and (select verified_seq from runs) = (select end_seq from runs) and (select epoch from runs) = 0
select count(*) = 2 and bool_and(verified_at is not null and digest is not null) from run_floors
select count(*) = 1 from outbox where type = 'RunVerified'
select count(*) = 2 from outbox where type = 'FloorVerified'
select count(*) = 0 from outbox where type in ('RunRolledBack', 'AntiCheatAlert')
select bool_and(verdict->>'startHash' is not null and verdict->>'endHash' is not null) from run_steps
