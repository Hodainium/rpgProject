select count(*) = 2 from pack_openings where pack_id = 'tiny'
select (select count from pack_inventory where pack_id = 'tiny') = 0 and (select sum(delta) from pack_ledger where pack_id = 'tiny') = 0
select count(*) = 1 from pack_openings where pack_id = 'tiny' and exists (select 1 from jsonb_array_elements(result->'cards') c where c->>'pity' = 'true' and c->>'rarity' = 'mythic')
select count(*) = 1 from pack_openings where pack_id = 'tiny' and not exists (select 1 from jsonb_array_elements(result->'cards') c where c->>'rarity' <> 'common')
select (select missed from pack_pity where pack_id = 'tiny' and rarity = 'mythic') = 0
select count(*) = 1 from pack_openings where pack_id = 'tiny' and pity_before->>'mythic' = '1'
select count(*) = 1 from outbox where type = 'PackTypeChanged' and payload->'payload'->>'packId' = 'tiny'
