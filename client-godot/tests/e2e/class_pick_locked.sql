select count(*) = 1 from runs where character_ids = array['demo.character.arcanist', 'demo.character.bard', 'demo.character.cleric']
select count(*) = 0 from runs where 'demo.character.pyromancer' = any(character_ids)
select count(*) = 1 from players where account_session > 0
