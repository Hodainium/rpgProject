select count(*) = 2 from pack_openings where pack_id = 'tiny'
select count(*) = 1 from pack_openings where pack_id = 'tiny' and result->'cards'->0->>'pity' = 'true' and result->'cards'->0->>'rarity' = 'mythic'
select count(*) = 1 from pack_openings where pack_id = 'tiny' and result->'cards'->0->>'rarity' = 'common'
select (select missed from pack_pity where pack_id = 'tiny' and rarity = 'mythic') = 0
select count(*) = 1 from pack_openings where pack_id = 'tiny' and pity_before->>'mythic' = '1'
select count(*) = 1 from outbox where type = 'PackTypeChanged' and payload->'payload'->>'packId' = 'tiny'
