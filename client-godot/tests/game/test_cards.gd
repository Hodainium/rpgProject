## Spec card-collection (Godot side, section 6): what a card is in content, the catalog export and its hash, the card validator
## rules, the core-set proposal, the run's item pool (picks restricted to it, hashed only when set, never in a snapshot, carried
## by a local save), the local test pool, and the server calls over a fake bridge. In-memory card fixtures (card_world.gd) and
## the test fixtures only: the user's content cannot fail these.
extends TestCase

const GOLDEN_FILE: String = GOLDEN + "game/card_catalog.json"
const SCRATCH: String = "user://test_cards/"
const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	super()


static func _ids(list: Array) -> Array:
	return list.map(func(card: Dictionary) -> String: return card["id"])


static func _query(tag: StringName) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([tag])
	return query


# --- What is a card -------------------------------------------------------------------------------------------------------

func test_cards_are_pooled_items_equipment_and_characters_sorted_by_id() -> void:
	var cards := CardCatalog.cards(CardWorld.content())
	var ids := _ids(cards)
	eq(cards.size(), 18, "13 item cards and 5 characters")
	var sorted := ids.duplicate()
	sorted.sort()
	eq(ids, sorted, "sorted by id")
	check(not ids.has("card.item.loose"), "an item in no pool is not a card")
	check(not ids.has("card.item.dev"), "a dev item is not a card")
	check(ids.has("card.gear.sword"), "a piece of equipment in a pool is an item card")
	var by_id := {}
	for card in cards:
		by_id[card["id"]] = card
	eq(by_id["card.hero.m1"]["rarity"], "mythic", "a character is Mythic")
	eq(by_id["card.hero.m1"]["kind"], "character", "a character card")
	eq(by_id["card.item.l1"]["rarity"], "legendary", "an item's rarity comes from Item.Rarity")
	eq(by_id["card.item.r2"]["pools"], ["Pool.Cache", "Pool.Shop"], "its pools, sorted")
	eq(by_id["card.item.c1"]["setId"], "core", "the set is the Card.Set tag, lowercase")
	check(by_id["card.item.c1"]["core"], "a card of the core set is core")
	check(not by_id["card.item.c2"]["core"], "a card of another set is not")
	eq(cards.filter(func(card: Dictionary) -> bool: return card["core"]).size(), 8, "3 core characters and 5 core items")


func test_core_item_ids_are_what_a_local_core_pool_holds() -> void:
	var ids: Array = CardCatalog.core_item_ids(CardWorld.content()).map(func(id: StringName) -> String: return String(id))
	eq(ids, ["card.item.boss1", "card.item.boss2", "card.item.c1", "card.item.cache1", "card.item.food"], "the core items in id order, no characters")


# --- The catalog file -----------------------------------------------------------------------------------------------------

func test_catalog_file_has_the_servers_shape_and_a_stable_hash() -> void:
	var content := CardWorld.content()
	var file := CardCatalog.catalog_file(content)
	eq(file.keys(), ["catalogHash", "cards"], "the CardCatalogFile fields, in the server's order")
	eq(file["cards"][0].keys(), ["id", "kind", "rarity", "setId", "core", "pools"], "the CatalogFileCard fields")
	eq(file["catalogHash"].length(), 64, "a SHA-256")
	eq(CardCatalog.catalog_file(content)["catalogHash"], file["catalogHash"], "the same content, the same hash")
	var changed := CardWorld.resources()
	for resource in changed:
		if resource is ItemDefinition and resource.id == &"card.item.r1":
			resource.tags.assign([&"Item.Rarity.Epic", &"Card.Set.Descent", &"Pool.Treasure"])
	check(CardCatalog.catalog_file(CardWorld.content(changed))["catalogHash"] != file["catalogHash"], "a changed rarity is a changed catalog")


func test_catalog_file_matches_its_golden() -> void:
	var text := WireJson.stringify(CardCatalog.catalog_file(CardWorld.content()))
	if update_goldens:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GOLDEN + "game/"))
		var file := FileAccess.open(GOLDEN_FILE, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(GOLDEN_FILE), "the catalog export matches its golden (the C# CardContractTests read the same file)")


# --- The card rules in the validator ---------------------------------------------------------------------------------------

func _codes(list: Array) -> Array:
	var codes: Array = list.map(func(problem: Array) -> String: return problem[0])
	codes.sort()
	return codes


func test_a_sound_card_set_has_no_problems() -> void:
	eq(CardCatalog.problems(CardWorld.content()), [], "no problems")


func test_content_without_card_rules_gets_no_card_checks() -> void:
	var list := CardWorld.untagged()
	list = list.filter(func(resource: Resource) -> bool: return not resource is CardRules)
	eq(CardCatalog.problems(CardWorld.content(list)), [], "no CardRules resource: no card checks at all")
	eq(CardCatalog.pool_counts(CardWorld.content(list)), {}, "and no pool targets")


func test_missing_double_and_unknown_sets_rarities_and_mythic_items_are_named() -> void:
	var list := CardWorld.resources()
	for resource in list:
		if resource is ItemDefinition and resource.id == &"card.item.c2":
			resource.tags.assign([&"Item.Rarity.Common", &"Pool.Treasure"])  # no set
		if resource is ItemDefinition and resource.id == &"card.item.c3":
			resource.tags.assign([&"Item.Rarity.Common", &"Card.Set.Descent", &"Card.Set.Core", &"Pool.Treasure"])  # two sets
		if resource is ItemDefinition and resource.id == &"card.item.c4":
			resource.tags.assign([&"Card.Set.Descent", &"Pool.Shop"])  # no rarity
		if resource is ItemDefinition and resource.id == &"card.item.r1":
			resource.tags.assign([&"Item.Rarity.Mythic", &"Card.Set.Descent", &"Pool.Treasure"])  # an item that is Mythic
	var codes := _codes(CardCatalog.problems(CardWorld.content(list)))
	check(codes.has("card_set_missing"), "a card with no set: %s" % [codes])
	check(codes.has("card_set_unknown"), "a card in two sets")
	check(codes.has("card_rarity_missing"), "an item with no rarity")
	check(codes.has("card_rarity_mismatch"), "an item cannot be Mythic")


func test_the_starter_characters_must_be_exactly_the_core_characters() -> void:
	var list := CardWorld.resources()
	for resource in list:
		if resource is CharacterDefinition and resource.id == &"card.hero.m1":
			resource.tags.assign([CardWorld.CORE])  # a fourth core character
	check(_codes(CardCatalog.problems(CardWorld.content(list))).has("core_character_count"), "a core character that is not a starter")


func test_a_pool_without_a_core_card_is_an_error() -> void:
	var list := CardWorld.resources()
	for resource in list:
		if resource is ItemDefinition and resource.id == &"card.item.cache1":
			resource.tags.assign([&"Item.Rarity.Rare", &"Card.Set.Descent", &"Pool.Cache"])  # the only core Cache card leaves the core set
	var problems := CardCatalog.problems(CardWorld.content(list))
	var empty: Array = problems.filter(func(problem: Array) -> bool: return problem[0] == "core_pool_empty").map(func(problem: Array) -> String: return problem[1])
	eq(empty, ["Pool.Cache"], "the Cache pool would be empty for a new account (the other pools still have a core card)")


func test_the_validator_reports_card_issues_and_a_short_pool_as_a_warning() -> void:
	var list := CardWorld.resources()
	for resource in list:
		if resource is CardRules:
			resource.pool_targets = {&"Pool.Treasure": 3, &"Pool.Shop": 5}
	var issues := ContentValidator.validate(CardWorld.content(list), {"tags": false})
	var short: Array = issues.filter(func(issue: ValidationIssue) -> bool: return issue.code == "core_pool_short")
	eq(short.size(), 2, "Shop and Treasure hold fewer core cards than their targets")
	check(not short[0].is_error(), "a short pool is a warning, not an error")


# --- The core-set proposal ----------------------------------------------------------------------------------------------

func test_the_proposal_takes_lowest_rarity_first_and_fills_every_target() -> void:
	var content := CardWorld.content(CardWorld.untagged())
	var proposal := CardCorePass.propose(content)
	eq(proposal["core_items"], ["card.item.boss1", "card.item.boss2", "card.item.c1", "card.item.c2", "card.item.c4",
		"card.item.cache1", "card.item.food", "card.item.r2"], "plain pools and Boss are core; then the commons, then the rare cards Cache needs")
	eq(proposal["short"], [], "no pool is short")
	eq(proposal["counts"]["Pool.Cache"], [2, 2], "Cache reaches its target exactly")
	eq(proposal["overshoot"], {"Pool.Shop": 1}, "an item counts in every pool it carries: c1 and r2 also fill Shop, which ends one over")
	eq(proposal["tags"]["card.hero.a"], CardWorld.CORE, "a starter character is core")
	eq(proposal["tags"]["card.hero.m1"], CardWorld.DESCENT, "the others are in the expansion set")
	eq(proposal["tags"]["card.item.c3"], CardWorld.DESCENT, "an item the pass did not need is collectible")
	eq(proposal["tags"]["card.item.c1"], CardWorld.CORE, "and the first common is core")


func test_the_proposal_is_deterministic_and_leaves_tagged_cards_alone() -> void:
	var content := CardWorld.content(CardWorld.untagged())
	eq(CardCorePass.propose(content), CardCorePass.propose(content), "the same content, the same proposal")
	var tagged := CardCorePass.propose(CardWorld.content())
	eq(tagged["tags"]["card.item.c2"], CardWorld.DESCENT, "a card that already has a set keeps it")
	eq(tagged["tags"]["card.item.c1"], CardWorld.CORE, "also a core one")


func test_a_pool_that_cannot_be_filled_is_reported_short() -> void:
	var list := CardWorld.untagged()
	for resource in list:
		if resource is CardRules:
			resource.pool_targets = {&"Pool.Cache": 9}
	var proposal := CardCorePass.propose(CardWorld.content(list))
	eq(proposal["short"], ["Pool.Cache"], "Cache has too few items for 9")
	eq(proposal["counts"]["Pool.Cache"][1], 9, "against its target")


func test_apply_patches_the_tags_line_and_nothing_else() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH + "apply/"))
	var directory := SCRATCH + "apply/"
	var made := {}
	for resource in CardWorld.untagged():
		if resource is ItemDefinition or resource is CardRules:
			var copy: Resource = resource.duplicate()
			made[resource.id] = directory + String(resource.id).replace(".", "_") + ".tres"
			check(ResourceSaver.save(copy, made[resource.id]) == OK, "saved %s" % resource.id)
	var content := ContentIndex.new(directory)
	eq(content.problems, PackedStringArray(), "the scratch content loads")
	var before := {}
	for id in made:
		before[id] = FileAccess.get_file_as_string(made[id])
	var proposal := CardCorePass.propose(content)
	var changed := CardCorePass.apply(content, proposal)
	check(changed.size() > 5, "files were tagged (%d)" % changed.size())
	for path in changed:
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)  # the first index cached the old files
	var reloaded := ContentIndex.new(directory)
	eq(reloaded.items[&"card.item.c1"].tags.has(CardWorld.CORE), true, "the core item carries the core tag")
	eq(reloaded.items[&"card.item.c3"].tags.has(CardWorld.DESCENT), true, "a collectible item carries the expansion tag")
	var after := FileAccess.get_file_as_string(made[&"card.item.c1"])
	var removed := PackedStringArray()
	for line in before[&"card.item.c1"].split("\n"):
		if not after.split("\n").has(line):
			removed.append(line)
	eq(removed.size(), 1, "exactly one line differs: the tags line (%s)" % [removed])
	eq(CardCorePass.apply(reloaded, CardCorePass.propose(reloaded)), [], "a second apply changes nothing: every card has its set")
	var unset: Array = CardCatalog.problems(reloaded).filter(func(problem: Array) -> bool: return problem[0] == "card_set_missing")
	eq(unset, [], "no item is left without a set")


# --- The run's item pool ---------------------------------------------------------------------------------------------------

func _pools(pool: Variant = null) -> Dictionary:
	var pools := {"party": [], "held": [], "seen": []}
	if pool != null:
		pools["card_pool"] = pool
	return pools


func test_picks_come_only_from_the_pool_when_there_is_one() -> void:
	var world := CardWorld.content()
	var structure: RunStructure = fixtures().runs.values()[0]
	var generator := FloorGenerator.new(world, structure, 1, 0)
	var treasure := _query(&"Pool.Treasure")
	var allowed: Array[StringName] = [&"card.item.c1", &"card.item.r1"]
	var outside := false
	for seed_value in 60:
		var restricted := generator.pick_item(null, treasure, RunSeeds.rng(seed_value, "t"), _pools(allowed))
		check(allowed.has(restricted.id), "seed %d picked %s from the pool" % [seed_value, restricted.id])
		var free := generator.pick_item(null, treasure, RunSeeds.rng(seed_value, "t"), _pools())
		outside = outside or not allowed.has(free.id)
	check(outside, "without a pool the same picks reach other items")


func test_an_empty_filtered_pool_gives_the_fallback_item() -> void:
	var world := CardWorld.content()
	var structure: RunStructure = fixtures().runs.values()[0]
	var generator := FloorGenerator.new(world, structure, 1, 0)
	var picked := generator.pick_item(null, _query(&"Pool.Treasure"), RunSeeds.rng(1, "t"), _pools([&"card.item.l1"]))
	eq(picked, structure.fallback_item, "no Treasure item is in the pool: the run's fallback")


func test_a_fixed_item_ignores_the_pool() -> void:
	var world := CardWorld.content()
	var generator := FloorGenerator.new(world, fixtures().runs.values()[0], 1, 0)
	var fixed: ItemDefinition = world.items[&"card.item.l1"]
	eq(generator.pick_item(fixed, null, RunSeeds.rng(1, "t"), _pools([&"card.item.c1"])), fixed, "named in the room: not a pool pick")


func test_pickups_and_equipment_follow_the_pool_too() -> void:
	var world := CardWorld.content()
	var generator := FloorGenerator.new(world, fixtures().runs.values()[0], 1, 0)
	var treasure := _query(&"Pool.Treasure")
	var picked: Resource = generator.pick_pickup(null, null, treasure, RunSeeds.rng(3, "t"), _pools([&"card.gear.sword"]))
	eq(picked.id, &"card.gear.sword", "items and equipment are one pool: only the sword is allowed")
	eq(generator.pick_equipment(treasure, RunSeeds.rng(3, "t"), _pools([&"card.item.c1"])), null, "no piece is in a pool of one item")
	eq(generator.pick_equipment(treasure, RunSeeds.rng(3, "t"), _pools([&"card.gear.sword"])).id, &"card.gear.sword", "the allowed piece")


func test_the_pool_restricts_a_whole_run_and_a_run_without_one_is_unchanged() -> void:
	var content := fixtures()
	var plain := RunController.new()
	host.add_child(plain)
	_nodes.append(plain)
	eq(plain.start_run(content, ["fixture.character.knight"], "7"), "", "a run without a pool starts")
	var pooled := RunController.new()
	host.add_child(pooled)
	_nodes.append(pooled)
	var pool: Array = [&"fixture.item.whetstone"]
	eq(pooled.start_run(content, ["fixture.character.knight"], "7", &"", pool), "", "a run with a pool starts")
	check(pooled.state.card_pool_set and not plain.state.card_pool_set, "only the second has a pool")
	var seen: Array[StringName] = []
	for index in pooled.state.map.sorted_indices():
		for pickup in pooled.state.map.cells[index]["pickups"]:
			seen.append(pickup["item"])
	for id in seen:
		check(id == &"fixture.item.whetstone" or id == structure_fallback(content) or _fixed(pooled, id), "%s is the pool's, the fallback or a fixed placement" % id)


static func structure_fallback(content: ContentIndex) -> StringName:
	var run: RunStructure = content.runs.values()[0]
	return run.fallback_item.id if run.fallback_item != null else &""


## A pickup the room names itself (not drawn from a pool).
func _fixed(run: RunController, id: StringName) -> bool:
	for room_id in run.content.rooms:
		for placement in run.content.rooms[room_id].placements:
			if placement != null and ((placement.item != null and placement.item.id == id) or (placement.equipment != null and placement.equipment.id == id)):
				return true
	return false


# --- The pool in the hash, in snapshots and in saves -------------------------------------------------------------------------

func test_the_pool_digest_ignores_order_and_the_hash_line_exists_only_when_set() -> void:
	var a := RunState.new()
	var b := RunState.new()
	a.set_card_pool([&"x", &"a", &"m"])
	b.set_card_pool([&"m", &"x", &"a"])
	eq(a.card_pool_digest(), b.card_pool_digest(), "the order the ids arrive in does not matter")
	check("\n".join(a.canonical_lines()).contains("card_pool="), "a run with a pool hashes it")
	check(not "\n".join(RunState.new().canonical_lines()).contains("card_pool"), "a run without one has no such line")
	check(a.run_hash() != RunState.new().run_hash(), "and the hashes differ")
	a.set_card_pool([&"x", &"a"])
	check(a.card_pool_digest() != b.card_pool_digest(), "a different pool, a different digest")


func test_a_snapshot_never_holds_the_pool_and_restore_takes_it_from_the_caller() -> void:
	var content := fixtures()
	var pool: Array = ["fixture.item.whetstone", "fixture.item.crest"]
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_run(content, ["fixture.character.knight"], "7", &"", pool), "", "the run starts")
	var snapshot: Dictionary = JSON.parse_string(WireJson.stringify(run.snapshot()))
	check(not JSON.stringify(snapshot).contains("cardPool") and not JSON.stringify(snapshot).contains("card_pool"), "no pool in the snapshot")
	var with_pool := RunController.new()
	host.add_child(with_pool)
	_nodes.append(with_pool)
	eq(with_pool.load_snapshot(content, snapshot, pool), "", "restored with the server's pool")
	eq(with_pool.state.run_hash(), run.state.run_hash(), "the same run hash")
	var without := RunController.new()
	host.add_child(without)
	_nodes.append(without)
	eq(without.load_snapshot(content, snapshot), "", "restored without a pool")
	check(without.state.run_hash() != run.state.run_hash(), "a run restored without its pool hashes differently")


func test_a_local_save_carries_the_pool() -> void:
	var content := fixtures()
	var pool: Array = ["fixture.item.whetstone"]
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_run(content, ["fixture.character.knight"], "7", &"", pool), "", "the run starts")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var path := SCRATCH + "local_%d.json" % Time.get_ticks_usec()
	check(LocalSave.write(path, run, content), "written")
	var read := LocalSave.read(path)
	eq(read["state"], "ok", "read back")
	eq(read["data"]["cardPool"], ["fixture.item.whetstone"], "the save holds the pool beside the snapshot")
	var again := RunController.new()
	host.add_child(again)
	_nodes.append(again)
	eq(again.load_snapshot(content, read["data"]["snapshot"], read["data"].get("cardPool")), "", "continued")
	eq(again.state.run_hash(), run.state.run_hash(), "with the same hash")
	var plain := RunController.new()
	host.add_child(plain)
	_nodes.append(plain)
	plain.start_run(content, ["fixture.character.knight"], "7")
	LocalSave.write(path, plain, content)
	check(not LocalSave.read(path)["data"].has("cardPool"), "a run without a pool writes no pool")
	LocalSave.delete(path)


func test_a_save_that_loses_or_changes_its_pool_is_noticed() -> void:
	var content := fixtures()
	var pool: Array = ["fixture.item.whetstone", "fixture.item.crest"]
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_run(content, ["fixture.character.knight"], "7", &"", pool), "", "the run starts")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var path := SCRATCH + "digest_%d.json" % Time.get_ticks_usec()
	LocalSave.write(path, run, content)
	var saved: Dictionary = LocalSave.read(path)["data"]
	eq(RunState.save_pool_problem(saved), "", "an intact save is fine")
	var lost := saved.duplicate(true)
	lost.erase("cardPool")
	check(RunState.save_pool_problem(lost).contains("lost"), "a save without its pool: %s" % RunState.save_pool_problem(lost))
	var stripped := saved.duplicate(true)  # review fix: the pool and its digest both gone
	stripped.erase("cardPool")
	stripped.erase("cardPoolDigest")
	check(RunState.save_pool_problem(stripped).contains("lost"), "a save that lost the pool and its digest: %s" % RunState.save_pool_problem(stripped))
	var widened := saved.duplicate(true)
	widened["cardPool"].append("fixture.item.banner")
	check(RunState.save_pool_problem(widened).contains("changed"), "a save with another pool")
	var reordered := saved.duplicate(true)
	reordered["cardPool"].reverse()
	eq(RunState.save_pool_problem(reordered), "", "the order does not matter")
	var plain := RunController.new()
	host.add_child(plain)
	_nodes.append(plain)
	plain.start_run(content, ["fixture.character.knight"], "7")
	LocalSave.write(path, plain, content)
	eq(RunState.save_pool_problem(LocalSave.read(path)["data"]), "", "a run without a pool writes no digest and is fine")
	LocalSave.delete(path)


func test_the_game_will_not_continue_a_local_save_that_lost_its_pool() -> void:
	var session := _session()
	var game: GameMain = session[0]
	game.local_saves = true
	game.local_save_path = SCRATCH + "continue_%d.json" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	game.local_card_pool = [&"fixture.item.whetstone"]
	eq(game.start_run(["fixture.character.knight"], "7", &"fixture.run.two_floors"), "", "a local run with a test pool")
	check(LocalSave.write(game.local_save_path, game.run, game.content), "saved")
	var file := FileAccess.get_file_as_string(game.local_save_path)
	var parsed: Dictionary = JSON.parse_string(file)
	parsed.erase("cardPool")
	var out := FileAccess.open(game.local_save_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(parsed))
	out.close()
	var error := game.continue_local_run()
	check(error.contains("lost its card pool"), "refused with the reason: %s" % error)
	LocalSave.delete(game.local_save_path)


# --- The local test pool (console) ------------------------------------------------------------------------------------------

func _session() -> Array:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	game.content_root = FIXTURES
	game.load_content()
	_nodes.append(game)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	console.attach(game)
	return [game, console]


func test_cards_local_sets_the_pool_new_local_runs_start_with() -> void:
	var session := _session()
	var game: GameMain = session[0]
	var console: DevConsole = session[1]
	var none: Dictionary = await console.execute("cards local core")
	check(not none["ok"], "the fixtures have no core cards: refused")
	var some: Dictionary = await console.execute("cards local fixture.item.crest fixture.item.whetstone")
	check(some["ok"], "two items: %s" % some["text"])
	eq(game.local_card_pool.size(), 2, "the game holds the test pool")
	var unknown: Dictionary = await console.execute("cards local fixture.item.nope")
	check(not unknown["ok"], "an unknown item is refused")
	eq(game.start_run(["fixture.character.knight"], "7", &"fixture.run.two_floors"), "", "a local run starts")
	check(game.run.state.card_pool_set and game.run.state.card_pool.size() == 2, "and takes the test pool")
	var all: Dictionary = await console.execute("cards local all")
	check(all["ok"] and game.local_card_pool == null, "all: today's behaviour")
	var shown: Dictionary = await console.execute("cards")
	check(shown["ok"] and shown["text"].contains("local mode"), "local mode says the account is on the server: %s" % shown["text"])


func test_the_server_commands_need_server_mode() -> void:
	var session := _session()
	var console: DevConsole = session[1]
	for line in ["packs", "packs open demo", "dust x", "craft x", "abandon"]:
		var result: Dictionary = await console.execute(line)
		check(not result["ok"], "'%s' needs a server" % line)


# --- The server calls over a fake bridge ------------------------------------------------------------------------------------

func _link(bridge: FakeBridge) -> ServerLink:
	var link := ServerLink.new(bridge)
	link.retry_base_seconds = 0.01
	link.saves_dir = "user://test_cards/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	host.add_child(link)
	_nodes.append(link)
	return link


func test_request_keys_are_uuid_v4_and_never_repeat() -> void:
	var seen := {}
	var pattern := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	for index in 50:
		var key := ServerLink.new_request_key()
		check(pattern.search(key) != null, "%s is a version 4 UUID" % key)
		check(not seen.has(key), "no repeat")
		seen[key] = true


func test_the_link_sends_the_account_calls_with_their_keys() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["OpenPack"] = [[true, {"openingId": "o", "packId": "p", "packVersion": 1, "gemsSpent": 100, "cards": [], "gems": 0, "dust": 0, "drawSeed": "1"}]]
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "", "runId": "r1", "runStatus": "Active"}]]
	bridge.answers["GetCollection"] = [[true, {"owned": [{"cardId": "item.a", "acquiredAt": "t", "source": "pack", "lockedByRunId": "r1"}], "gems": 5, "dust": 40,
		"version": 2, "activeRunId": "r1", "activeRunStatus": "Active", "pity": [{"packId": "p", "missedPacks": {"legendary": 7}}]}]]
	var link := _link(bridge)
	var key := ServerLink.new_request_key()
	var opened: Dictionary = await link.open_pack("p", key)
	check(opened["ok"], "the open is answered")
	eq(JSON.parse_string(bridge.of("OpenPack")[0][2]), {"requestKey": key}, "the body is the request key")
	eq(bridge.of("OpenPack")[0][1], "p", "for that pack")
	var dusted: Dictionary = await link.dust_card("item.a", key)
	check(not dusted["ok"], "the dust is refused")
	eq(dusted["error"]["errorCode"], 1403, "with the run lock's code")
	eq(dusted["error"]["runId"], "r1", "and the run that holds the card")
	var collection: Dictionary = await link.get_collection()
	var text := ServerLink.describe_collection(collection["data"])
	check(text.contains("gems 5, dust 40") and text.contains("item.a") and text.contains("locked by the run") and text.contains("legendary 7"),
		"the collection reads: %s" % text)


func test_abandon_and_the_admin_calls_reach_the_bridge() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["AbandonRun"] = [[true, null]]
	bridge.answers["PutCardRate"] = [[true, {"rarity": "epic", "dustValue": 100, "craftCost": 400, "version": 2, "createdBy": "dev"}]]
	var link := _link(bridge)
	var abandoned: Dictionary = await link.abandon_run("run-1")
	check(abandoned["ok"], "the cancel is answered")
	eq(bridge.of("AbandonRun")[0][1], "run-1", "for that run")
	var rate: Dictionary = await link.request("PutCardRate", [WireJson.stringify({"rarity": "epic", "dustValue": 100, "craftCost": 400})])
	check(rate["ok"], "an admin call goes through request()")


func test_a_cancelled_run_stops_uploading_and_loses_its_save() -> void:
	var bridge := FakeBridge.new()
	var link := _link(bridge)
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	eq(run.start_server_run(fixtures(), ["fixture.character.knight"], "run-9", 5150, &"fixture.run.two_floors"), "", "a server run")
	link.link(run, "run-9")
	check(run.journal and run.verify_wins, "linked: journalled and held for the verdict")
	link.release_cancelled("another-run")
	check(run.journal, "another run's cancel changes nothing here")
	link.release_cancelled("run-9")
	check(not run.journal and not run.verify_wins, "cancelled: no more uploads, no verdict to wait for")
	check(link.queued().is_empty(), "the queue is dropped")
	check(not FileAccess.file_exists(link.save_path()), "and there is no save to continue")


func test_a_won_server_run_blocks_leaving_until_the_server_accepts_it() -> void:
	var session := _session()
	var game: GameMain = session[0]
	eq(game.start_run(["fixture.character.knight"], "7"), "", "a run to hold the state (a local start; only the state matters)")
	game.server = ServerLink.new(FakeBridge.new())   # server mode, without a network
	host.add_child(game.server)
	_nodes.append(game.server)
	game.set_mode("run")
	check(not game.leaving_blocked(), "an active run can be left")
	game.run.state.status = RunState.WON
	check(game.leaving_blocked(), "a won run waiting for the verdict cannot")
	var left := false
	game.mode_changed.connect(func(new_mode: String) -> void: left = left or new_mode == "menu")
	game.back_to_menu()
	game.save_and_quit()
	check(not left, "back_to_menu and save_and_quit stay where they are")
	game.set_mode("end")
	check(not game.leaving_blocked(), "once the server accepted it (the end screen) the player can leave")
	game.back_to_menu()
	eq(game.mode, "menu", "and does")


# --- The card console commands against a fake server --------------------------------------------------------------------------

## A GameMain in server mode over a fake bridge, and the console attached to it.
func _server_session(bridge: FakeBridge) -> Array:
	var session := _session()
	var game: GameMain = session[0]
	var link := _link(bridge)
	game.server = link
	return [game, session[1], link]


const COLLECTION := {"owned": [{"cardId": "item.a", "acquiredAt": "t", "source": "pack", "lockedByRunId": "r1"},
	{"cardId": "item.b", "acquiredAt": "t", "source": "craft", "lockedByRunId": null}], "gems": 5, "dust": 40, "version": 2,
	"activeRunId": "r1", "activeRunStatus": "Active", "pity": [{"packId": "p", "missedPacks": {"legendary": 7, "mythic": 3}}]}


func test_the_cards_command_shows_the_account() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["GetCollection"] = [[true, COLLECTION]]
	var session := _server_session(bridge)
	var result: Dictionary = await session[1].execute("cards")
	check(result["ok"], "cards works: %s" % result["text"])
	for part in ["gems 5, dust 40", "2 collected", "item.a", "locked by the run", "item.b", "pity p", "legendary 7"]:
		check(result["text"].contains(part), "the account line has '%s': %s" % [part, result["text"]])
	bridge.answers["GetCollection"] = [[false, {"status": 503, "errorCode": null, "title": "down", "detail": ""}]]
	var down: Dictionary = await session[1].execute("cards")
	check(not down["ok"] and down["text"].contains("503"), "a server error is a failed command: %s" % down["text"])


func test_the_packs_command_lists_opens_and_shows_pity() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["GetPacks"] = [[true, {"packs": [{"packId": "descent-pack", "name": "Descent", "version": 1, "priceGems": 100, "cardCount": 5,
		"oddsPer10000": {"common": 7210, "rare": 2200, "epic": 450, "legendary": 100, "mythic": 40}, "setIds": ["descent"], "cardIds": [],
		"pityPacks": {"epic": 10, "legendary": 20, "mythic": 30}, "firstGuarantees": {}, "minRarityPerPack": "rare"}]}]]
	bridge.answers["OpenPack"] = [[true, {"openingId": "o", "packId": "descent-pack", "packVersion": 1, "gemsSpent": 100, "gems": 400, "dust": 25,
		"drawSeed": "9", "cards": [{"cardId": "item.a", "rarity": "common", "duplicate": false, "dustGained": 0, "pity": false},
			{"cardId": "item.b", "rarity": "rare", "duplicate": true, "dustGained": 20, "pity": false},
			{"cardId": "hero.m", "rarity": "mythic", "duplicate": false, "dustGained": 0, "pity": true}]}]]
	bridge.answers["GetCollection"] = [[true, COLLECTION]]
	var session := _server_session(bridge)
	var listed: Dictionary = await session[1].execute("packs")
	check(listed["ok"] and listed["text"].contains("descent-pack: 100 gems, 5 cards") and listed["text"].contains("common 72.10%")
		and listed["text"].contains("pity epic 10") and listed["text"].contains("at least a rare"), "the pack line: %s" % listed["text"])
	var opened: Dictionary = await session[1].execute("packs open descent-pack")
	check(opened["ok"], "open works: %s" % opened["text"])
	for part in ["opened descent-pack", "for 100 gems", "gems 400, dust 25", "common item.a  NEW", "(duplicate: +20 dust)", "[pity]"]:
		check(opened["text"].contains(part), "the opening has '%s': %s" % [part, opened["text"]])
	var sent: Dictionary = JSON.parse_string(bridge.of("OpenPack")[0][2])
	check(opened["text"].contains(str(sent["requestKey"])), "the reply prints the request key the call used")
	eq(bridge.of("OpenPack")[0][1], "descent-pack", "for that pack")
	var retried: Dictionary = await session[1].execute("packs open descent-pack 11111111-2222-4333-8444-555555555555")
	check(retried["ok"], "a retry with a key")
	eq(JSON.parse_string(bridge.of("OpenPack")[1][2])["requestKey"], "11111111-2222-4333-8444-555555555555", "uses the key it was given")
	var pity: Dictionary = await session[1].execute("packs pity")
	check(pity["ok"] and pity["text"].contains("p: packs since") and pity["text"].contains("mythic 3"), "the pity counters: %s" % pity["text"])
	var bad: Dictionary = await session[1].execute("packs open")
	check(not bad["ok"], "open needs a pack id")


func test_the_dust_command_resolves_first_and_names_the_locking_run() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["GetCollection"] = [[true, COLLECTION]]
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "Card locked by the run", "detail": "", "runId": "r1", "runStatus": "Active"}],
		[true, {"cardId": "item.a", "dustGained": 5, "rateVersion": 2, "dust": 45}]]
	var session := _server_session(bridge)
	var locked: Dictionary = await session[1].execute("dust first")
	check(not locked["ok"] and locked["text"].contains("1403") and locked["text"].contains("r1") and locked["text"].contains("Active")
		and locked["text"].contains("abandon"), "the lock is explained: %s" % locked["text"])
	eq(bridge.of("DustCard")[0][1], "item.a", "'first' is the first card of the collection")
	var done: Dictionary = await session[1].execute("dust item.a")
	check(done["ok"] and done["text"].contains("dusted item.a: +5 dust (rate version 2), dust now 45"), "a dust: %s" % done["text"])
	var none: Dictionary = await session[1].execute("dust")
	check(not none["ok"], "a card id is needed")


func test_the_craft_command_reports_the_cost_and_the_refusal() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["CraftCard"] = [[false, {"status": 409, "errorCode": 1402, "title": "Not enough currency", "detail": ""}],
		[true, {"cardId": "item.e1", "dustSpent": 400, "rateVersion": 1, "dust": 60}]]
	var session := _server_session(bridge)
	var poor: Dictionary = await session[1].execute("craft item.e1")
	check(not poor["ok"] and poor["text"].contains("1402") and poor["text"].contains("key "), "a refusal names its code and the key: %s" % poor["text"])
	var crafted: Dictionary = await session[1].execute("craft item.e1")
	check(crafted["ok"] and crafted["text"].contains("crafted item.e1 for 400 dust") and crafted["text"].contains("dust now 60"), "a craft: %s" % crafted["text"])


func test_the_abandon_command_cancels_the_run_on_the_server() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["AbandonRun"] = [[true, null], [false, {"status": 409, "errorCode": 1410, "title": "A run is being verified", "detail": ""}]]
	var session := _server_session(bridge)
	var nothing: Dictionary = await session[1].execute("abandon")
	check(not nothing["ok"] and nothing["text"].contains("no server run"), "no run on screen and no id: %s" % nothing["text"])
	var named: Dictionary = await session[1].execute("abandon run-7")
	check(named["ok"] and named["text"].contains("run run-7 abandoned"), "by id: %s" % named["text"])
	eq(bridge.of("AbandonRun")[0][1], "run-7", "the call names the run")
	var verifying: Dictionary = await session[1].execute("abandon run-8")
	check(not verifying["ok"] and verifying["text"].contains("1410"), "a run being verified cannot be cancelled: %s" % verifying["text"])


func test_the_server_pack_type_command_merges_into_the_latest_version() -> void:
	var latest := {"packId": "descent-pack", "name": "Descent Pack", "version": 2, "priceGems": 100, "cardCount": 5,
		"oddsPer10000": {"common": 7210, "rare": 2200, "epic": 450, "legendary": 100, "mythic": 40}, "setIds": ["descent"], "retired": false,
		"pityPacks": {"epic": 10}, "firstGuarantees": {"epic": 5}, "minRarityPerPack": "rare", "createdBy": "dev"}
	var bridge := FakeBridge.new()
	bridge.answers["ListPackTypes"] = [[true, {"packTypes": [latest]}]]
	bridge.answers["PutPackType"] = [[true, latest.merged({"version": 3, "priceGems": 150}, true)]]
	var session := _server_session(bridge)
	var listed: Dictionary = await session[1].execute("server pack-type")
	check(listed["ok"] and listed["text"].contains("descent-pack v2: 100 gems, 5 cards"), "the list: %s" % listed["text"])
	var changed: Dictionary = await session[1].execute("server pack-type descent-pack price=150 min=none pity=epic:8,legendary:20")
	check(changed["ok"] and changed["text"].contains("v3") and changed["text"].contains("150 gems"), "a change: %s" % changed["text"])
	var body: Dictionary = JSON.parse_string(bridge.of("PutPackType")[0][1])
	eq(body["priceGems"], 150, "the new price")
	eq(body["cardCount"], 5, "what was left out keeps the latest version's value")
	eq(body["oddsPer10000"]["mythic"], 40, "also the odds")
	check(not body.has("minRarityPerPack"), "min=none clears the guarantee")
	eq([int(body["pityPacks"]["epic"]), int(body["pityPacks"]["legendary"]), body["pityPacks"].size()], [8, 20, 2], "pity=… replaces the map")
	var incomplete: Dictionary = await session[1].execute("server pack-type brand-new price=10")
	check(not incomplete["ok"] and incomplete["text"].contains("needs price, cards, odds and sets"), "a new pack needs its basics: %s" % incomplete["text"])
	var unknown: Dictionary = await session[1].execute("server pack-type descent-pack colour=red")
	check(not unknown["ok"] and unknown["text"].contains("unknown option"), "an unknown option is refused")


func test_the_server_card_rate_command_lists_and_writes() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["ListCardRates"] = [[true, {"rates": [{"rarity": "epic", "dustValue": 100, "craftCost": 400, "version": 1, "createdBy": "seed"}]}]]
	bridge.answers["PutCardRate"] = [[true, {"rarity": "epic", "dustValue": 130, "craftCost": 520, "version": 2, "createdBy": "dev"}]]
	var session := _server_session(bridge)
	var listed: Dictionary = await session[1].execute("server card-rate")
	check(listed["ok"] and listed["text"].contains("epic: dust 100, craft 400 (version 1"), "the list: %s" % listed["text"])
	var put: Dictionary = await session[1].execute("server card-rate epic 130 520")
	check(put["ok"] and put["text"].contains("dust 130, craft 520 (version 2"), "a write: %s" % put["text"])
	var rate_body: Dictionary = JSON.parse_string(bridge.of("PutCardRate")[0][1])
	eq([rate_body["rarity"], int(rate_body["dustValue"]), int(rate_body["craftCost"])], ["epic", 130, 520], "the body")
	var bad: Dictionary = await session[1].execute("server card-rate epic x 5")
	check(not bad["ok"] and bad["text"].contains("usage"), "numbers are whole: %s" % bad["text"])


func test_refused_passes_only_for_a_refusal_with_that_text() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["GetCollection"] = [[true, COLLECTION]]
	bridge.answers["DustCard"] = [[false, {"status": 409, "errorCode": 1403, "title": "locked", "detail": "", "runId": "r1", "runStatus": "Active"}],
		[false, {"status": 409, "errorCode": 1403, "title": "locked", "detail": "", "runId": "r1", "runStatus": "Active"}],
		[true, {"cardId": "item.a", "dustGained": 5, "rateVersion": 1, "dust": 5}]]
	var session := _server_session(bridge)
	var ok: Dictionary = await session[1].execute("refused 1403 dust first")
	check(ok["ok"] and ok["text"].contains("refused as expected"), "a refusal with its code: %s" % ok["text"])
	var wrong: Dictionary = await session[1].execute("refused 9999 dust first")
	check(not wrong["ok"] and wrong["text"].contains("not with '9999'"), "another text is a failure: %s" % wrong["text"])
	var worked: Dictionary = await session[1].execute("refused 1403 dust first")
	check(not worked["ok"] and worked["text"].contains("it worked"), "a command that works is a failure: %s" % worked["text"])
	var empty: Dictionary = await session[1].execute("refused 1403")
	check(not empty["ok"], "it needs a command")


# --- Continue for a won run waiting for its verdict ------------------------------------------------------------------------

func _write_save(link: ServerLink, run_id: String, last_acked: int, end: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(link.save_path().get_base_dir()))
	var file := FileAccess.open(link.save_path(), FileAccess.WRITE)
	file.store_string(JSON.stringify({"schemaVersion": 1, "runId": run_id, "player": link.player, "floorSeeds": {}, "snapshot": {"run": {"status": "Won"}},
		"queue": [], "lastAckedSeq": last_acked, "end": end, "epoch": 0}))
	file.close()


func test_continue_offers_a_verifying_run_only_from_a_save_that_holds_its_end() -> void:
	var bridge := FakeBridge.new()
	bridge.answers["GetCurrentRun"] = [[true, {"runId": "r-9", "status": "Verifying", "currentFloor": 0, "lastSeq": 6, "startedAt": "2026-11-09T12:00:00+00:00"}]]
	var session := _server_session(bridge)
	var game: GameMain = session[0]
	var link: ServerLink = session[2]

	var without_save: Dictionary = await game.can_continue()
	check(not without_save["enabled"] and without_save["reason"] == "verifying", "no save: there is nothing to show but the wait is not ours: %s" % [without_save])

	_write_save(link, "r-9", 6, {})
	var no_end: Dictionary = await game.can_continue()
	check(not no_end["enabled"] and no_end["reason"] == "verifying", "a save without the end request cannot resume the wait")

	_write_save(link, "r-9", 3, {"seq": 4, "status": "Won", "runHash": "h", "snapshot": {}})
	var behind: Dictionary = await game.can_continue()
	check(not behind["enabled"], "a save behind the server's log is not offered (resume_into would refuse it)")

	_write_save(link, "other-run", 6, {"seq": 7, "status": "Won", "runHash": "h", "snapshot": {}})
	var other: Dictionary = await game.can_continue()
	check(not other["enabled"], "another run's save is not offered")

	_write_save(link, "r-9", 6, {"seq": 7, "status": "Won", "runHash": "h", "snapshot": {}})
	var ready: Dictionary = await game.can_continue()
	check(ready["enabled"] and ready["tag"] == "Synced" and ready["subtitle"].contains("waiting for the server"), "a current save with its end request: %s" % [ready])
	forget_save(link)


func forget_save(link: ServerLink) -> void:
	link.forget_save()
