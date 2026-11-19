select count(*) = 1 from account_requests where kind = 'pack'
select count(*) = 1 from pack_openings where pack_id = 'descent-pack' and jsonb_array_length(result->'cards') = 5
select (select count(*) from pack_ledger where reason = 'open' and delta = -1) = 1
select count(*) = 1 and bool_and(count = 0) from pack_inventory where pack_id = 'descent-pack'
select (select count(*) from card_holdings) + (select count(*) from wallet_ledger where reason = 'duplicate') = 5
