select count(*) = 1 from players where display_name = 'e2e-stairs'
select count(*) = 1 from runs where status = 'Active' and current_floor = 1
select count(*) = 2 from run_floors
select min(seq) = 1 and count(*) = max(seq) from run_actions
select (select last_seq from runs where status = 'Active') = (select count(*) from run_actions)
select bool_and(snapshot is not null) from run_actions where type in ('start_run', 'battle', 'next_floor')
select count(*) = 1 from run_actions where type = 'next_floor'
select (select count(*) from battle_sessions) = (select count(*) from run_actions where type = 'battle')
