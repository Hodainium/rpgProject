select count(*) >= 2 from completion_marks where challenge_id = 'fixture.challenge.boss_trial.win'
select bool_and(cycle_key = to_char(now(), 'IYYY-"W"IW')) from completion_marks where challenge_id like 'fixture.challenge.boss_trial.%'
select count(*) = (select count(*) from completion_marks where challenge_id like 'fixture.challenge.boss_trial.%') from wallet_ledger where challenge_id like 'fixture.challenge.boss_trial.%'
select bool_and(delta = case challenge_id when 'fixture.challenge.boss_trial.flawless' then 15 else 10 end) from wallet_ledger where challenge_id like 'fixture.challenge.boss_trial.%'
select (select count(*) from wallet_ledger where challenge_id = 'fixture.challenge.boss_trial.win') = (select count(*) from completion_marks where challenge_id = 'fixture.challenge.boss_trial.win')
select (select gems from wallets) = (select sum(delta) from wallet_ledger)
select count(*) = (select count(*) from wallet_ledger where challenge_id like 'fixture.challenge.boss_trial.%') from outbox where type = 'RewardGranted' and payload->'payload'->>'challengeId' like 'fixture.challenge.boss_trial.%'
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
