select count(*) >= 2 from completion_marks
select count(*) = count(distinct (character_id, boss_id)) from completion_marks
select (select gems from wallets) = (select sum(delta) from wallet_ledger) and (select sum(delta) from wallet_ledger) = 10 * (select count(*) from completion_marks)
select count(*) = (select count(*) from completion_marks) from outbox where type = 'RewardGranted' and destination = 'redpanda'
select count(*) = count(distinct idempotency_key) from wallet_ledger
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
select count(*) >= 1 from outbox where type = 'BattleVerified' and destination = 'redpanda'
