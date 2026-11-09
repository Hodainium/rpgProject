select (select count(*) from runs where status = 'Won') = 1 and (select count(*) from runs where status = 'Abandoned') = 1
select (select count(*) from runs where card_pool is not null) = 2
select (select count(*) from card_ledger where delta = -1) = 1 and (select count(*) from outbox where type = 'CardDusted') = 1
select (select count(*) from card_holdings) = (select count(*) from card_ledger where delta = 1) - 1
select w.dust = coalesce((select sum(delta) from wallet_ledger where currency = 'dust' and status = 'released'), 0) from wallets w
select (select count(*) from account_requests where kind = 'dust') = 1
