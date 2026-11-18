select (select max(account_session) from players) = 3
select (select count(*) from wallet_ledger where reason = 'pack_buy') = 0 and (select count(*) from account_requests) = 0
select (select count(*) from pack_ledger) = 0
