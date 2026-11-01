select count(*) >= 2 from battle_sessions
select count(*) = 1 from battle_sessions where status = 'Rejected'
select (select count(*) from battle_sessions where status = 'Verified') = (select count(*) from battle_sessions) - 1
select bool_and(verdict->>'errorCode' = '2002' and verdict->>'error' = 'ReplayMismatch' and verdict->'mismatch'->>'reason' = 'FinalHashMismatch') from battle_sessions where status = 'Rejected'
select bool_and(run_seq = (select min(run_seq) from battle_sessions)) from battle_sessions where status = 'Rejected'
select bool_and(attempts = 1 and dead_lettered_at is null) from battle_sessions
