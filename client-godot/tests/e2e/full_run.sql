select count(*) = 1 from runs where status in ('Won', 'Lost') and ended_at is not null
select min(seq) = 1 and count(*) = max(seq) from run_actions
select (select last_seq from runs) = (select count(*) from run_actions)
select count(*) = 1 from run_actions where type = 'end'
select max(seq) = (select max(seq) from run_actions where type = 'end') from run_actions
select bool_and(snapshot is not null) from run_actions where type in ('start_run', 'battle', 'next_floor')
select count(*) >= 2 from battle_sessions
select (select count(*) from battle_sessions) = (select count(*) from run_actions where type = 'battle')
select bool_and(b.ruleset_version = r.ruleset_version) from battle_sessions b join runs r using (run_id)
