select count(*) = 1 from runs where status = 'Active' and current_floor = 1
select count(*) = 2 from run_floors
select min(seq) = 1 and count(*) = max(seq) from run_actions
select (select last_seq from runs where status = 'Active') = (select count(*) from run_actions)
select count(*) = 1 from run_actions where type = 'next_floor'
