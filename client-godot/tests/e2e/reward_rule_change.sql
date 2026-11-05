select count(*) = 3 from completion_marks
select (select bool_and(delta = 10 and rule_version = 1) from wallet_ledger where idempotency_key ~ ':fixture.character.(knight|medic):')
select (select bool_and(delta = 25 and rule_version = 2) from wallet_ledger where idempotency_key ~ ':fixture.character.rogue:')
select (select gems from wallets) = 45 and (select sum(delta) from wallet_ledger) = 45
select count(*) = 3 from outbox where type = 'RewardRuleChanged' and payload->'payload'->>'version' = '2'
select bool_and(published_at is not null) from outbox where destination = 'redpanda'
