select count(*) >= 1 from battle_sessions
select bool_and(status = 'Verified' and verdict is not null) from battle_sessions
select bool_and(verdict->>'finalStateHash' = action_log->>'claimedFinalHash') from battle_sessions
select bool_and(verdict->>'outcome' = action_log->>'claimedOutcome') from battle_sessions
select bool_and(attempts = 1 and dead_lettered_at is null) from battle_sessions
select bool_and(conditions->>'encounterId' like 'demo.%') from battle_sessions
