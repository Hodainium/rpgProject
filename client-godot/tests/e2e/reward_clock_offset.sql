select (select gems from wallets) = 70 and (select sum(delta) from wallet_ledger) = 70
select count(*) = 2 from completion_marks where challenge_id = 'event.trial' and cycle_key like '2126-W%'
select count(*) = 0 from completion_marks where challenge_id = 'event.short'
select count(*) = 0 from wallet_ledger where challenge_id = 'event.short'
select bool_and(cycle_key like '2126-W%') from wallet_ledger
