select count(*) = 1 from runs where status = 'Active' and current_floor = 1
select min(seq) = 1 and count(*) = max(seq) from run_actions
select count(*) = 0 from run_actions where state_hash like 'conflict-%'
