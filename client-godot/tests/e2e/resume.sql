select count(*) = 1 from runs
select min(seq) = 1 and count(*) = max(seq) from run_actions
select count(*) = 1 from run_actions where type = 'end'
