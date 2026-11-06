select (select gems from wallets) = 60 and (select sum(delta) from wallet_ledger) = 60
select count(distinct cycle_key) = 3 from completion_marks
select (select array_agg(distinct cycle_key order by cycle_key) from completion_marks) = array['once', 'once.p1', 'once.r1.p1']
select count(distinct n) = 1 from (select count(*) n from completion_marks group by cycle_key) per_key
select (select count(*) from reward_cycle_resets where player_id is not null) = 3 and (select count(*) from reward_cycle_resets where player_id is null) = 3
select count(*) = 6 from outbox where type = 'RewardCycleReset'
select bool_and(delta = 10 and rule_version = 1) from wallet_ledger
select count(*) = (select count(*) from completion_marks) from outbox where type = 'RewardGranted' and destination = 'redpanda'
select count(*) = count(distinct idempotency_key) from wallet_ledger
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
