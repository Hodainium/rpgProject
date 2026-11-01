select count(*) >= 2 from battle_sessions
select bool_and(status = 'Verified' and verdict is not null) from battle_sessions
select count(*) = count(distinct battle_id) from battle_sessions
select bool_and(attempts = 1 and dead_lettered_at is null) from battle_sessions
