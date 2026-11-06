select count(*) >= 2 from completion_marks where challenge_id = 'fixture.challenge.boss_trial'
select bool_and(best_tier between 1 and 3) from completion_marks where challenge_id = 'fixture.challenge.boss_trial'
select bool_and(cycle_key = to_char(now(), 'IYYY-"W"IW')) from completion_marks where challenge_id = 'fixture.challenge.boss_trial'
select count(*) >= 2 from wallet_ledger where challenge_id = 'fixture.challenge.boss_trial' and tier = 1 and delta = 10
select count(*) = (select count(*) from wallet_ledger where challenge_id = 'fixture.challenge.boss_trial') from wallet_ledger l where challenge_id = 'fixture.challenge.boss_trial' and delta = case tier when 3 then 15 else 10 end
select (select coalesce(sum(delta), 0) from wallet_ledger where challenge_id = 'fixture.challenge.boss_trial') = (select sum(case best_tier when 1 then 10 when 2 then 20 else 35 end) from completion_marks where challenge_id = 'fixture.challenge.boss_trial')
select (select gems from wallets) = (select sum(delta) from wallet_ledger)
select count(*) = (select count(*) from wallet_ledger where challenge_id = 'fixture.challenge.boss_trial') from outbox where type = 'RewardGranted' and payload->'payload'->>'challengeId' = 'fixture.challenge.boss_trial'
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
