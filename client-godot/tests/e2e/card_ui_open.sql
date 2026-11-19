select count(*) = 1 from account_requests where kind = 'pack_buy'
select count(*) = 1 from account_requests where kind = 'pack'
select count(*) = 1 from wallet_ledger where reason = 'pack_buy' and delta = -200
select (select count(*) from pack_ledger where reason = 'buy' and delta = 2) = 1 and (select count(*) from pack_ledger where reason = 'open' and delta = -1) = 1
select count(*) = 1 and bool_and(count = 1) from pack_inventory where pack_id = 'descent-pack'
select count(*) = 1 from pack_openings where pack_id = 'descent-pack' and jsonb_array_length(result->'cards') = 5
select (select count(*) from card_holdings) + (select count(*) from wallet_ledger where reason = 'duplicate') = 5
select w.gems = coalesce((select sum(delta) from wallet_ledger where currency = 'gems' and status = 'released'), 0) from wallets w
select w.dust = coalesce((select sum(delta) from wallet_ledger where currency = 'dust' and status = 'released'), 0) from wallets w
