select count(*) = 2 from runs
select count(*) = 1 from runs where 'demo.character.vampire' = any(character_ids)
select count(*) = 0 from run_steps where status <> 'Verified'
select count(*) >= 1 from battle_sessions b join runs r using (run_id) where 'demo.character.vampire' = any(r.character_ids) and b.status = 'Verified'
select count(*) = 0 from battle_sessions where status <> 'Verified'
select count(*) = 1 from pack_openings where pack_id = 'bloodmoon-pack' and jsonb_array_length(result->'cards') = 5
select count(*) = 1 from pack_ledger where pack_id = 'bloodmoon-pack' and reason = 'buy' and delta = 1
select count(*) = 1 from card_ledger where card_id = 'demo.character.vampire' and reason = 'craft' and delta = 1
select count(*) = 1 from card_ledger where reason = 'dust' and delta = -1
select count(*) = 1 from card_holdings where card_id = 'demo.character.vampire'
select count(*) = 0 from card_holdings h join cards c using (card_id) where c.set_id <> 'bloodmoon'
select (select count(*) from card_holdings) = (select count(*) from card_ledger where delta = 1) - (select count(*) from card_ledger where delta = -1)
select w.gems = coalesce((select sum(delta) from wallet_ledger where currency = 'gems' and status = 'released'), 0) from wallets w
select w.dust = coalesce((select sum(delta) from wallet_ledger where currency = 'dust' and status = 'released'), 0) from wallets w
select count(*) = 1 from outbox where type = 'PackOpened'
select count(*) = 1 from outbox where type = 'CardCrafted'
select count(*) = 1 from outbox where type = 'CardDusted'
