## The card fixtures (spec card-collection 6): a content index built in memory, never a content folder and never the demo, so the
## user's tuning cannot fail a card test and no fixture file can change another test's content (the same idea as keys_world.gd).
## Two sets (core and "descent"), every rarity, every room pool the core set must fill, characters of both kinds, one equipment
## piece, an item outside every pool and a dev item. Targets (Treasure 3, Shop 2, Cache 2) are small on purpose. Mirrors the
## server's CardFixtures (tests/Rpg.GameServerApi.Tests/CardFixtures.cs) in spirit, not item for item.
class_name CardWorld
extends RefCounted

const CORE: StringName = &"Card.Set.Core"
const DESCENT: StringName = &"Card.Set.Descent"
const STARTERS: Array[StringName] = [&"card.hero.a", &"card.hero.b", &"card.hero.c"]


static func item(id: String, rarity: String, set_tag: StringName, pools: Array) -> ItemDefinition:
	var made := ItemDefinition.new()
	made.id = StringName(id)
	made.display_name = id
	var tags: Array[StringName] = [StringName("Item.Rarity." + rarity.capitalize())]
	if set_tag != &"":
		tags.append(set_tag)
	for pool in pools:
		tags.append(StringName("Pool." + str(pool)))
	made.tags = tags
	return made


static func piece(id: String, rarity: String, set_tag: StringName, pools: Array) -> EquipmentDefinition:
	var made := EquipmentDefinition.new()
	made.id = StringName(id)
	made.display_name = id
	made.slot = &"Slot.Weapon"
	var tags: Array[StringName] = [StringName("Item.Rarity." + rarity.capitalize())]
	if set_tag != &"":
		tags.append(set_tag)
	for pool in pools:
		tags.append(StringName("Pool." + str(pool)))
	made.tags = tags
	return made


static func hero(id: String, set_tag: StringName) -> CharacterDefinition:
	var made := CharacterDefinition.new()
	made.id = StringName(id)
	made.display_name = id
	var tags: Array[StringName] = []
	if set_tag != &"":
		tags.append(set_tag)
	made.tags = tags
	return made


static func _dev_item() -> ItemDefinition:
	var made := item("card.item.dev", "Common", &"", ["Treasure"])
	made.tags.append(FloorGenerator.DEV_TAG)
	return made


static func rules(targets: Dictionary = {&"Pool.Treasure": 3, &"Pool.Shop": 2, &"Pool.Cache": 2},
		all_core: Array[StringName] = [&"Pool.Boss"]) -> CardRules:
	var made := CardRules.new()
	made.id = &"card.rules"
	made.pool_targets = targets
	made.all_core_pools = all_core
	made.starter_characters = STARTERS.duplicate()
	return made


## Everything a catalog test needs. Core: the three starters, the boss items, the plain (Food) item, c1 and a Cache item. Descent: the rest.
static func resources() -> Array:
	return [
		hero("card.hero.a", CORE), hero("card.hero.b", CORE), hero("card.hero.c", CORE),
		hero("card.hero.m1", DESCENT), hero("card.hero.m2", DESCENT),
		item("card.item.c1", "Common", CORE, ["Treasure", "Shop"]),
		item("card.item.c2", "Common", DESCENT, ["Treasure"]),
		item("card.item.c3", "Common", DESCENT, ["Treasure"]),
		item("card.item.c4", "Common", DESCENT, ["Shop"]),
		item("card.item.r1", "Rare", DESCENT, ["Treasure"]),
		item("card.item.r2", "Rare", DESCENT, ["Shop", "Cache"]),
		item("card.item.e1", "Epic", DESCENT, ["Treasure", "Cache"]),
		item("card.item.l1", "Legendary", DESCENT, ["Cache"]),
		item("card.item.cache1", "Rare", CORE, ["Cache"]),
		item("card.item.boss1", "Epic", CORE, ["Boss"]),
		item("card.item.boss2", "Legendary", CORE, ["Boss", "Treasure"]),
		item("card.item.food", "Common", CORE, ["Food"]),
		piece("card.gear.sword", "Rare", DESCENT, ["Treasure"]),
		item("card.item.loose", "Common", &"", []),   # in no pool: not a card
		_dev_item(),   # a dev item (tag Dev): never a card
		rules(),
	]


## The same set with no set tags at all (what the demo content looks like before the proposal is applied), as the starting
## point of the core-selection pass.
static func untagged() -> Array:
	var list: Array = []
	for resource in resources():
		if resource is ItemDefinition or resource is EquipmentDefinition:
			var plain: Resource = resource.duplicate()
			var kept: Array[StringName] = []
			for tag in resource.tags:
				if not String(tag).begins_with(CardCatalog.SET_PREFIX):
					kept.append(tag)
			plain.tags = kept
			list.append(plain)
		elif resource is CharacterDefinition:
			var plain: CharacterDefinition = resource.duplicate()
			plain.tags.assign([])
			list.append(plain)
		else:
			list.append(resource)
	return list


static func content(list: Array = []) -> ContentIndex:
	return ContentIndex.new("").overlay(list if not list.is_empty() else resources())
