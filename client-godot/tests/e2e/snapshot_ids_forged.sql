select (select status from runs) = 'Won' and (select epoch from runs) = 0 and (select rollbacks from runs) = 0
select count(*) = 1 from run_actions where snapshot #>> '{run,seenItems,0}' like '%,%'
select count(*) = 1 from run_actions where snapshot #>> '{run,seenItems,0}' like '%,%' and verified_snapshot is not null and not (verified_snapshot #>> '{run,seenItems,0}' like '%,%') and jsonb_array_length(verified_snapshot #> '{run,seenItems}') = jsonb_array_length(snapshot #> '{run,seenItems}') + 1
select count(*) > 2 from run_actions where verified_snapshot is not null
select count(*) = 0 from run_steps where status = 'Rejected'
select count(*) = 0 from run_steps where verdict ? 'endSnapshot' and kind <> 'genesis'
select (select verified_seq from runs) = (select end_seq from runs)
select count(*) = 1 from outbox where type = 'RunVerified'
select count(*) = 0 from outbox where type = 'AntiCheatAlert'
