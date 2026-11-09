select count(*) >= 2 from completion_marks
select (select gems from wallets) = 10 * (select count(*) from completion_marks)
select count(*) = (select count(*) from completion_marks) from outbox where type = 'RewardGranted' and destination = 'redpanda'
select bool_and(published_at is not null and dead_lettered_at is null) from outbox where destination = 'redpanda'
select count(*) = count(distinct id) from outbox
select bool_or(attempts > 0) from outbox where destination = 'redpanda'
select count(*) >= 3 and bool_and(published_at > (select at from e2e_marks where name = 'redpanda-start')) from outbox where destination = 'redpanda' and type <> 'RewardRuleChanged'  -- the seed rules went out before the broker stopped
