## Spec class-pick 2.3-2.5 and 3.2: what the class pick shows, pure and testable headless: who may be picked (ownership), a
## class's moves, level skills and stats, the party's slots (add, remove, a preset) and the footer line. The screen draws it and
## never decides ownership itself. Presentation and menu logic only: never read by combat/, the run or the verifier.
class_name ClassPickModel
extends RefCounted

## Ownership states (2.3).
const OPEN: String = "open"      # pickable, no card system involved (local mode, or content without cards)
const CORE: String = "core"      # a core-set (starter) class: every account owns it
const OWNED: String = "owned"    # a class card the account owns
const LOCKED: String = "locked"  # not owned: shown greyed, cannot be added

## Move types, in the order the class card lists them.
const TYPE_ORDER: Array[String] = ["Basic", "Skill", "FollowUp", "Passive", "Ultimate"]
## Abilities every class has (ult charge, break passives, SP gain, Block): left out of a class's moves.
const SHARED_PREFIXES: Array[String] = ["Ability.Passive.Ultcharge", "Ability.Passive.Break", "Ability.Passive.Spgain",
	"Ability.Block"]
## The stats shown, in order: attribute key in stats_x100 → label (2.1, D5: plain numbers).
const STATS: Array = [["max_hp", "HP"], ["atk", "ATK"], ["def", "DEF"], ["spd", "SPD"], ["max_mp", "SP"]]

static var _abilities: Dictionary = {}  # PackedScene -> {name, tag, assets}, read once per scene


## Character id → OPEN / CORE / OWNED / LOCKED. `core_ids` are the content's core-set cards (CardCatalog.core_ids; empty when the
## content has no card system, then every class is OPEN). `collection` is a CollectionResponse (server mode with a session) or
## null; with `server_mode` false every class is OPEN (local mode, spec card-ui 2.6). Server mode with no collection: only the
## core classes are pickable (the read failed or there is no session).
static func ownership(character_ids: Array, core_ids: Array, collection: Variant, server_mode: bool) -> Dictionary:
	var core := {}
	for id in core_ids:
		core[String(id)] = true
	var owned := {}
	if collection is Dictionary:
		for card in collection.get("owned", []):
			if card is Dictionary:
				owned[str(card.get("cardId", ""))] = true
	var result := {}
	for id in character_ids:
		var key := String(id)
		if not server_mode or core.is_empty():
			result[key] = OPEN
		elif core.has(key):
			result[key] = CORE
		elif owned.has(key):
			result[key] = OWNED
		else:
			result[key] = LOCKED
	return result


static func pickable(state: String) -> bool:
	return state != LOCKED


## The class's moves: [{name, type}] with type one of TYPE_ORDER, shared abilities left out, sorted by type (stable within one).
## Names through AbilityName.of, types from the ability's tag and its Ability.Type.* asset tags.
static func moves(character: CharacterDefinition) -> Array:
	var found: Array = []
	for scene in character.abilities:
		var info := _ability(scene)
		if info.is_empty() or _shared(String(info["tag"])):
			continue
		found.append({"name": info["name"], "type": _type_of(info)})
	var sorted: Array = []
	for type in TYPE_ORDER:
		for move in found:
			if move["type"] == type:
				sorted.append(move)
	return sorted


## The level skills: [[level, name]] in the order the class lists them.
static func learns(character: CharacterDefinition) -> Array:
	var rows: Array = []
	for row in character.level_skills:
		if row == null or row.ability == null:
			continue
		var info := _ability(row.ability)
		rows.append([row.level, info.get("name", "?")])
	return rows


## [[label, number]] for STATS, from stats_x100 (stored ×100, shown as the designer typed them; whole numbers stay whole).
static func stats(character: CharacterDefinition) -> Array:
	var rows: Array = []
	for pair in STATS:
		if character.stats_x100.has(pair[0]):
			rows.append([pair[1], _number(int(character.stats_x100[pair[0]]))])
	return rows


## Puts `id` in the first empty slot. The party is an Array of `max_party` entries, each a character id or &"" (empty). Unchanged
## when the class is already in it or the party is full.
static func add(party: Array, id: StringName, max_party: int) -> Array:
	var result := normalized(party, max_party)
	if result.has(id):
		return result
	var slot := result.find(&"")
	if slot >= 0:
		result[slot] = id
	return result


## Empties `slot`; the later members keep their slots (2.4).
static func remove(party: Array, slot: int, max_party: int) -> Array:
	var result := normalized(party, max_party)
	if slot >= 0 and slot < result.size():
		result[slot] = &""
	return result


## A preset in its order; a class that is not pickable (or unknown) leaves its slot empty. {party, missing}.
static func apply_preset(members: Array, states: Dictionary, max_party: int) -> Dictionary:
	var party: Array = []
	var missing := 0
	for index in max_party:
		var id: StringName = StringName(members[index]) if index < members.size() else &""
		if id == &"":
			party.append(&"")
		elif states.has(String(id)) and pickable(states[String(id)]) and not party.has(id):
			party.append(id)
		else:
			party.append(&"")
			missing += 1
	return {"party": party, "missing": missing}


## A saved party (ids) restored: members no longer pickable, unknown or repeated leave their slot empty.
static func restore(saved: Array, states: Dictionary, max_party: int) -> Array:
	return apply_preset(saved, states, max_party)["party"]


## Exactly `max_party` entries, StringNames, "" for an empty slot.
static func normalized(party: Array, max_party: int) -> Array:
	var result: Array = []
	for index in max_party:
		result.append(StringName(party[index]) if index < party.size() and party[index] != null else &"")
	return result


## The members in slot order, empty slots skipped.
static func members(party: Array) -> Array:
	return party.filter(func(id) -> bool: return StringName(id) != &"")


## The footer line (D9): "" for a full party, "Only N slots filled." below it, `empty_text` with nobody.
static func footer(party: Array, max_party: int, short_text: String = "Only %d slot%s filled.",
		empty_text: String = "Pick at least one class.") -> String:
	var count := members(party).size()
	if count == 0:
		return empty_text
	if count >= max_party:
		return ""
	return short_text % [count, "" if count == 1 else "s"]


static func _ability(scene: PackedScene) -> Dictionary:
	if scene == null:
		return {}
	if not _abilities.has(scene):
		var node := scene.instantiate()
		var info := {}
		if node is GameplayAbility:
			var assets: Array[StringName] = []
			if node is BattleAbility:
				assets = (node as BattleAbility).asset_tags
			info = {"name": AbilityName.of(node), "tag": node.ability_tag, "assets": assets.duplicate()}
		node.free()
		_abilities[scene] = info
	return _abilities[scene]


static func _shared(tag: String) -> bool:
	for prefix in SHARED_PREFIXES:
		if tag == prefix or tag.begins_with(prefix + "."):
			return true
	return false


static func _type_of(info: Dictionary) -> String:
	var assets: Array = info["assets"]
	var tag := String(info["tag"])
	if assets.has(&"Ability.Type.Ultimate") or tag.begins_with("Ability.Ult."):
		return "Ultimate"
	if assets.has(&"Ability.Type.Basic"):
		return "Basic"
	if assets.has(&"Ability.Type.FollowUp"):
		return "FollowUp"
	if tag.begins_with("Ability.Passive."):
		return "Passive"
	return "Skill"


static func _number(x100: int) -> String:
	if x100 % 100 == 0:
		return str(x100 / 100)
	return str(Fixed.to_display(x100))
