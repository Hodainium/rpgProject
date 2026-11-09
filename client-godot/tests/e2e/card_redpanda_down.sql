select count(*) = 1 from pack_openings
select (select count(*) from card_ledger where delta = -1) = 1
select bool_and(published_at is not null and dead_lettered_at is null) from outbox where destination = 'redpanda'
select count(*) = 1 and bool_and(published_at > (select at from e2e_marks where name = 'redpanda-start')) from outbox where type = 'PackOpened'
select count(*) = 1 and bool_and(published_at > (select at from e2e_marks where name = 'redpanda-start')) from outbox where type = 'CardDusted'
select bool_and(attempts > 0) from outbox where type in ('PackOpened', 'CardDusted')
select count(*) = count(distinct id) from outbox
