select count(*) >= 2 from battle_sessions
select bool_and(status = 'Verified' and verdict is not null and verified_at is not null) from battle_sessions
select bool_and(verdict->>'status' = 'Verified' and verdict->>'errorCode' is null and verdict->'mismatch' = 'null'::jsonb) from battle_sessions
select bool_and(verdict->>'finalStateHash' = action_log->>'claimedFinalHash') from battle_sessions
select bool_and(verdict->>'outcome' = action_log->>'claimedOutcome') from battle_sessions
select bool_and(verdict->>'verifierRulesetVersion' = ruleset_version and verifier_version = ruleset_version) from battle_sessions
select bool_and(attempts = 1 and dead_lettered_at is null and enqueued_at is not null) from battle_sessions
select count(*) = (select count(*) from run_actions where type = 'battle') from battle_sessions
