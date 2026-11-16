select (select status from runs) = 'Won' and (select card_pool from runs) is not null and jsonb_array_length((select card_pool from runs)) >= 80
select count(*) = 0 from run_steps where status <> 'Verified'
select count(*) = 1 from pack_openings where pack_id = 'descent-pack' and jsonb_array_length(result->'cards') = 5
select count(*) = 1 from account_requests where kind = 'pack'
select count(*) = 1 from account_requests where kind = 'pack_buy'
select count(*) = 1 from wallet_ledger where reason = 'pack_buy' and delta = -100
select count(*) = 0 from wallet_ledger where reason = 'pack_open'
select (select count(*) from pack_ledger where reason = 'buy' and delta = 1) = 1 and (select count(*) from pack_ledger where reason = 'open' and delta = -1 and opening_id is not null) = 1
select count(*) = 1 and bool_and(count = 0) from pack_inventory where pack_id = 'descent-pack'
select w.gems = coalesce((select sum(delta) from wallet_ledger where currency = 'gems' and status = 'released'), 0) from wallets w
select w.dust = coalesce((select sum(delta) from wallet_ledger where currency = 'dust' and status = 'released'), 0) from wallets w
select (select count(*) from card_holdings) = (select count(*) from card_ledger where delta = 1)
select (select count(*) from card_holdings) + (select count(*) from wallet_ledger where reason = 'duplicate') = 5
select count(*) = 0 from card_holdings h join cards c using (card_id) where c.core
select count(*) = 1 from outbox where type = 'PackOpened'
select count(*) = 1 from outbox where type = 'PackPurchased'
