select (select gems from wallets) = 210 and (select sum(delta) from wallet_ledger where status = 'released') = 210
select count(*) = 18 from wallet_ledger where status = 'released' and challenge_id like 'event.trial.%'
select (select count(*) from wallet_ledger where status = 'released' and challenge_id = 'event.trial.win' and delta = 10) = 6 and (select count(*) from wallet_ledger where status = 'released' and challenge_id = 'event.trial.fast' and delta = 10) = 6 and (select count(*) from wallet_ledger where status = 'released' and challenge_id = 'event.trial.flawless' and delta = 15) = 6
select count(*) = 18 from completion_marks
select count(distinct cycle_key) = 3 from completion_marks
select count(*) = 6 from completion_marks where cycle_key = to_char(now(), 'IYYY-"W"IW')
select count(*) = 6 from completion_marks where cycle_key = to_char(now(), 'IYYY-"W"IW') || '.p1'
select count(*) = 6 from completion_marks where cycle_key = to_char(now(), 'IYYY-"W"IW') || '.r1.p1'
select (select count(*) from reward_cycle_resets) = 6
select count(*) = 18 from outbox where type = 'RewardGranted' and destination = 'redpanda'
select count(*) = 6 from outbox where type = 'RewardCycleReset'
select count(*) = count(distinct idempotency_key) from wallet_ledger
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
