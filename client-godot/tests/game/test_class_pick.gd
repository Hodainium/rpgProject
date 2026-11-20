## Spec class-pick 6: the class pick. ClassPickModel (ownership from the three sources, moves, level skills, stats, the party's
## slots, presets, the footer), the turntable's index headless (wrap, shortest way, only turn moves it), the screen over the
## fixtures (local mode) and over a fake server with the card fixtures (locked classes, presets with an unowned class, Lock in,
## a 1409), the dev run setup, the validator's party_preset_* codes, and the console commands. Fixtures only.
extends TestCase

const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge
const CardWorld = preload("res://tests/game/card_world.gd")
const SCREEN: String = "res://presentation/demo/ui/class_pick/class_pick.tscn"
const MENU: StringName = &"UI.Layer.Menu"
const MODAL: StringName = &"UI.Layer.Modal"
const RUN: String = "fixture.run.two_floors"

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func _frames(count: int) -> void:
	for i in count:
		await host.get_tree().process_frame


func _game(bridge: FakeBridge = null, card_content: bool = false) -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	game.local_saves = false
	if card_content:
		var list := CardWorld.resources()
		list.append(fixtures().runs[StringName(RUN)])  # a run to start (the server answers before it is played)
		game.content = CardWorld.content(list)
	if bridge != null:
		var link := ServerLink.new(bridge)
		link.retry_base_seconds = 0.01
		link.retry_max_seconds = 0.02
		link.player = "tester"
		link.url = "http://fake:5000"
		link.saves_dir = "user://test_class_pick/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
		game.use_server(link)
	return game


func _open(game: GameMain) -> UIScreen:
	await _frames(2)
	var screen := game.ui.push(MENU, load(SCREEN))
	for i in 120:
		if screen == null or not screen.loading:
			break
		await _frames(1)
	await _frames(1)
	return screen


func _collection(owned: Array) -> Dictionary:
	return {"owned": owned.map(func(id: String) -> Dictionary: return {"cardId": id, "count": 1}), "gems": 0, "dust": 0,
		"accountVersion": 3, "activeRunId": null, "activeRunStatus": null, "pity": [], "ownedPacks": []}


func _catalog() -> Dictionary:
	return {"catalogVersion": 1, "catalogHash": "x", "cards": Array(CardCatalog.cards(CardWorld.content()))}


func _card_bridge(owned: Array, catalog: Variant = null) -> FakeBridge:
	var bridge := FakeBridge.new()
	bridge.answers["GetCardCatalog"] = [[true, catalog if catalog != null else _catalog()]]
	bridge.answers["StartAccountSession"] = [[true, {"session": 1, "collection": _collection(owned)}]]
	bridge.answers["GetCollection"] = [[true, _collection(owned)]]
	bridge.answers["GetCurrentRun"] = [[true, null]]
	return bridge


func _preset(id: String, members: Array) -> PartyPreset:
	var preset := PartyPreset.new()
	preset.id = StringName(id)
	preset.display_name = id.capitalize()
	preset.members.assign(members.map(func(member: String) -> StringName: return StringName(member)))
	return preset


func _index_of(screen: UIScreen, id: String) -> int:
	var characters: Array = screen.get_node("%Carousel").characters
	for i in characters.size():
		if String(characters[i].id) == id:
			return i
	return -1


# --- ClassPickModel ----------------------------------------------------------------------------------------------------

func test_ownership_from_the_three_sources() -> void:
	var ids := ["card.hero.a", "card.hero.m1", "card.hero.m2"]
	var core := [&"card.hero.a", &"card.item.c1"]
	var local := ClassPickModel.ownership(ids, core, null, false)
	eq(local.values(), [ClassPickModel.OPEN, ClassPickModel.OPEN, ClassPickModel.OPEN], "local mode: every class is pickable")
	var read := ClassPickModel.ownership(ids, core, _collection(["card.hero.m1"]), true)
	eq([read["card.hero.a"], read["card.hero.m1"], read["card.hero.m2"]],
		[ClassPickModel.CORE, ClassPickModel.OWNED, ClassPickModel.LOCKED], "server: core, owned, locked")
	var unknown := ClassPickModel.ownership(ids, core, null, true)
	eq([unknown["card.hero.a"], unknown["card.hero.m1"]], [ClassPickModel.CORE, ClassPickModel.LOCKED],
		"server with no collection: only the core classes")
	var no_cards := ClassPickModel.ownership(ids, [], null, true)
	eq(no_cards["card.hero.m2"], ClassPickModel.OPEN, "content without cards: nothing to lock")
	check(not ClassPickModel.pickable(ClassPickModel.LOCKED) and ClassPickModel.pickable(ClassPickModel.OWNED), "pickable")


func test_moves_learns_and_stats_follow_the_definition() -> void:
	for character: CharacterDefinition in fixtures().characters.values():
		var moves := ClassPickModel.moves(character)
		for move: Dictionary in moves:
			check(ClassPickModel.TYPE_ORDER.has(move["type"]), "%s: a known type %s" % [character.id, move["type"]])
			check(not ["Block", "Ult Charge", "Sp Gain"].has(move["name"]), "%s: shared ability %s left out" % [character.id, move["name"]])
		var order: Array = moves.map(func(move: Dictionary) -> int: return ClassPickModel.TYPE_ORDER.find(move["type"]))
		var sorted := order.duplicate()
		sorted.sort()
		eq(order, sorted, "%s: moves listed by type" % character.id)
		eq(ClassPickModel.learns(character).size(), character.level_skills.filter(func(row) -> bool:
			return row != null and row.ability != null).size(), "%s: one line per level skill" % character.id)
		for row in ClassPickModel.stats(character):
			var key: String = ClassPickModel.STATS.filter(func(pair: Array) -> bool: return pair[1] == row[0])[0][0]
			var x100 := int(character.stats_x100[key])
			eq(row[1], str(x100 / 100) if x100 % 100 == 0 else str(snappedf(x100 / 100.0, 0.01)),
				"%s %s shown as typed" % [character.id, row[0]])


func test_party_slots_presets_and_footer() -> void:
	var party := ClassPickModel.normalized([], 4)
	eq(party, [&"", &"", &"", &""], "four empty slots")
	party = ClassPickModel.add(party, &"a", 4)
	party = ClassPickModel.add(party, &"b", 4)
	eq(ClassPickModel.add(party, &"a", 4), party, "a class is in the party once")
	party = ClassPickModel.remove(party, 0, 4)
	eq(party, [&"", &"b", &"", &""], "a removal leaves a hole; later members keep their slots")
	eq(ClassPickModel.add(party, &"c", 4), [&"c", &"b", &"", &""], "the next add fills the first hole")
	var full := [&"a", &"b", &"c", &"d"]
	eq(ClassPickModel.add(full, &"e", 4), full, "a full party takes no one")
	var states := {"a": ClassPickModel.CORE, "b": ClassPickModel.LOCKED, "c": ClassPickModel.OWNED, "d": ClassPickModel.LOCKED}
	var applied := ClassPickModel.apply_preset([&"a", &"b", &"c", &"d"], states, 4)
	eq(applied, {"party": [&"a", &"", &"c", &""], "missing": 2}, "two locked classes: two empty slots (D8)")
	eq(ClassPickModel.apply_preset([&"a", &"zz"], states, 4)["party"], [&"a", &"", &"", &""], "an unknown class leaves its slot empty")
	eq(ClassPickModel.footer([&"a", &"", &"", &""], 4), "Only 1 slot filled.", "one member")
	eq(ClassPickModel.footer([&"a", &"b", &"", &""], 4), "Only 2 slots filled.", "two members (D9)")
	eq(ClassPickModel.footer(full, 4), "", "a full party says nothing")
	eq(ClassPickModel.footer([&"", &"", &"", &""], 4), "Pick at least one class.", "nobody")


# --- The turntable -----------------------------------------------------------------------------------------------------

func test_carousel_turns_and_wraps() -> void:
	var carousel := ClassCarousel3D.new()
	carousel.build_views = false
	host.add_child(carousel)
	var list: Array = fixtures().characters.values()
	list.append_array(CardWorld.content().characters.values())
	carousel.show_characters(list)
	var count := list.size()
	var emitted: Array = []
	carousel.selected_changed.connect(func(index: int) -> void: emitted.append(index))
	carousel.turn(-1)
	eq(carousel.index, count - 1, "left of the first is the last")
	carousel.turn(1)
	eq(carousel.index, 0, "and back")
	carousel.select(count - 1)
	eq(carousel.index, count - 1, "select goes the shortest way")
	eq(emitted, [count - 1, 0, count - 1], "selected_changed once per turn")
	check(carousel.turning(), "the ring eases toward the selection")
	carousel.free()


# --- The screen, local mode ----------------------------------------------------------------------------------------------

func test_new_run_opens_the_class_pick_without_run_or_seed_fields() -> void:
	var game := _game()
	await _frames(2)
	game.ui.top(MENU).get_node("%NewRun").pressed.emit()
	await _frames(3)
	var screen := game.ui.top(MENU)
	eq(screen.scene_file_path, SCREEN, "New run pushes the class pick")
	for unique in ["%Seed", "%RunPicker", "%ContentRoot"]:
		check(screen.get_node_or_null(unique) == null, "no %s (D10)" % unique)
	check(screen.states.values().all(func(state: String) -> bool: return state == ClassPickModel.OPEN),
		"local mode: every class is pickable")


func test_only_the_arrows_turn_the_ring() -> void:
	var game := _game()
	var screen := await _open(game)
	var carousel: ClassCarousel3D = screen.get_node("%Carousel")
	var start := carousel.index
	screen.get_node("%Next").pressed.emit()
	eq(carousel.index, wrapi(start + 1, 0, carousel.characters.size()), "the right arrow")
	screen.get_node("%Prev").pressed.emit()
	eq(carousel.index, start, "the left arrow")
	var key := InputEventAction.new()
	key.action = &"ui_right"
	key.pressed = true
	screen._input(key)
	eq(carousel.index, wrapi(start + 1, 0, carousel.characters.size()), "Right turns it")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	screen._input(wheel)
	eq(carousel.index, wrapi(start + 1, 0, carousel.characters.size()), "the wheel does not (D13)")


func test_building_a_party_and_locking_in() -> void:
	var game := _game()
	var screen := await _open(game)
	screen.party = ClassPickModel.normalized([], screen.max_party)
	screen.get_node("%Carousel").select(_index_of(screen, "fixture.character.knight"))
	screen.get_node("%Add").pressed.emit()
	eq(screen.party[0], &"fixture.character.knight", "Add fills the first slot")
	eq(screen.get_node("%Add").text, screen.remove_text, "and becomes Remove")
	eq(screen.get_node("%Footer").text, "Only 1 slot filled.", "the footer")
	screen.get_node("%Slots").get_child(0).pressed.emit()
	eq(screen.party[0], &"", "a click on the member removes it")
	check(screen.get_node("%LockIn").disabled, "Lock in needs a member")
	screen.get_node("%Add").pressed.emit()
	game.dev_run_setup = {"run_id": RUN, "seed": "1234"}
	screen.refresh()
	check(screen.get_node("%DevLine").visible and screen.get_node("%DevLine").text.contains(RUN), "the dev setup line shows")
	screen.get_node("%LockIn").pressed.emit()
	await _frames(3)
	eq(game.mode, "run", "Lock in starts the run")
	eq(String(game.run.state.run_structure_id), RUN, "the dev setup's run")
	eq(Array(game.run.state.party_characters()), [&"fixture.character.knight"], "with the party")


func test_lock_in_without_a_dev_setup_plays_the_default_run() -> void:
	var game := _game()
	var screen := await _open(game)
	screen.get_node("%LockIn").pressed.emit()
	await _frames(3)
	eq(game.mode, "run", "the run starts")
	var picked := RunController.pick_run(game.content, &"")
	eq(String(game.run.state.run_structure_id), String(picked["run"].id), "the content's default run (D11)")


func test_a_preset_loads_in_order() -> void:
	var game := _game()
	var screen := await _open(game)
	var ids: Array = screen.get_node("%Carousel").characters.map(func(character) -> String: return String(character.id))
	screen.apply_preset(_preset("pair", [ids[1], ids[0]]))
	eq(screen.party.slice(0, 2), [StringName(ids[1]), StringName(ids[0])], "the preset's order")
	check(screen.get_node("%Message").text.contains("loaded"), "the message line says so")


# --- The screen, server mode ---------------------------------------------------------------------------------------------

func test_server_mode_locks_classes_the_account_lacks() -> void:
	var game := _game(_card_bridge(["card.hero.m1"]), true)
	var screen := await _open(game)
	eq([screen.states["card.hero.a"], screen.states["card.hero.m1"], screen.states["card.hero.m2"]],
		[ClassPickModel.CORE, ClassPickModel.OWNED, ClassPickModel.LOCKED], "core, owned, locked")
	screen.get_node("%Carousel").select(_index_of(screen, "card.hero.m2"))
	await _frames(1)
	check(screen.get_node("%Add").disabled, "Add is disabled on a locked class")
	eq(screen.get_node("%Hint").text, "Find card.hero.m2 in a pack or craft it.", "with the pack hint")
	check(screen.get_node("%Description").get_node("%Extra").text.contains(screen.locked_chip), "and the Locked chip on the card")
	screen.apply_preset(_preset("mixed", ["card.hero.a", "card.hero.m2", "card.hero.m1"]))
	eq(screen.party, [&"card.hero.a", &"", &"card.hero.m1", &""], "the locked member's slot stays empty (D8)")
	check(screen.get_node("%Message").text.contains("1 class not owned"), "the line counts it: " + screen.get_node("%Message").text)


func test_no_collection_leaves_only_the_core_classes() -> void:
	var bridge := _card_bridge([])
	bridge.answers["GetCollection"] = [[false, {"status": 503, "errorCode": null, "title": "unavailable"}]]
	var game := _game(bridge, true)
	var screen := await _open(game)
	eq(screen.states["card.hero.m1"], ClassPickModel.LOCKED, "not known to be owned")
	eq(screen.states["card.hero.a"], ClassPickModel.CORE, "core stays pickable")
	check(screen.get_node("%Message").text.contains("Couldn't check"), "the line says why")


func test_a_1409_rereads_ownership_and_empties_the_slot() -> void:
	var bridge := _card_bridge(["card.hero.m1"])
	var game := _game(bridge, true)
	var screen := await _open(game)
	screen.party = [&"card.hero.a", &"card.hero.m1", &"", &""]
	bridge.answers["GetCollection"] = [[true, _collection([])]]
	bridge.answers["StartRun"] = [[false, {"status": 400, "errorCode": 1409, "title": "Character not unlocked"}]]
	screen.get_node("%LockIn").pressed.emit()
	for i in 60:
		if screen.get_node("%Message").text.contains("not on your account"):
			break
		await _frames(1)
	eq(game.mode, "menu", "no run starts")
	eq(screen.party, [&"card.hero.a", &"", &"", &""], "the lost member's slot is empty")
	eq(screen.get_node("%Message").text, "card.hero.m1 is not on your account any more. Pick another class.", "named")
	check(not screen.get_node("%LockIn").disabled, "Lock in works again")


# --- Validator and console ---------------------------------------------------------------------------------------------

func test_preset_validator_codes() -> void:
	var content := fixtures()
	var ids: Array = content.characters.keys().map(func(id) -> String: return String(id))
	var list := PartyPresetList.new()
	list.presets.assign([_preset("good", [ids[0]]), _preset("unknown", ["fixture.character.nobody"]),
		_preset("big", [ids[0], ids[1], ids[0], ids[1], ids[0]]), _preset("good", [ids[1]])])
	var codes: Array = ClassPickCheck.validate(list, content).map(func(issue: ValidationIssue) -> String: return issue.code)
	for code in ["party_preset_unknown_character", "party_preset_too_big", "party_preset_duplicate"]:
		check(codes.has(code), "reports %s: %s" % [code, codes])
	var hidden: CharacterDefinition = content.characters.values()[0].duplicate()
	hidden.selectable = false
	var hidden_content := ContentIndex.new("").overlay([hidden])
	var hidden_list := PartyPresetList.new()
	hidden_list.presets.assign([_preset("hidden", [String(hidden.id)])])
	eq(ClassPickCheck.validate(hidden_list, hidden_content).map(func(issue: ValidationIssue) -> String: return issue.code),
		["party_preset_not_selectable"], "a class that cannot be picked")
	if skip_in_export():
		return
	eq(ClassPickCheck.validate_screen(ContentIndex.new("res://content/")).size(), 0,
		"the screen's presets name real classes")


func test_console_classpick_and_runsetup() -> void:
	var game := _game()
	await _frames(2)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	check(console.commands.has("classpick") and console.commands.has("runsetup"), "both commands exist (tool parity)")
	var opened: Dictionary = await console.execute("classpick open")
	check(opened["ok"] and opened["text"].begins_with("class pick open"), opened["text"])
	check(not (await console.execute("runsetup seed nope"))["ok"], "a bad seed is refused")
	var set: Dictionary = await console.execute("runsetup run %s" % RUN)
	check(set["ok"] and set["text"].contains(RUN), set["text"])
	var state: Dictionary = await console.execute("classpick state")
	check(state["text"].contains("Dev run setup: " + RUN), state["text"])
	check(not (await console.execute("classpick turn x"))["ok"], "turn needs a number")
	await console.execute("runsetup clear")
	eq(game.dev_run_setup, {}, "clear goes back to the defaults")


# --- Review fixes ------------------------------------------------------------------------------------------------------

func test_a_reread_keeps_owned_members() -> void:
	var bridge := _card_bridge(["card.hero.m1"])
	var game := _game(bridge, true)
	var screen := await _open(game)
	screen.party = [&"card.hero.a", &"card.hero.m1", &"", &""]
	await screen.load_ownership()   # a session change or a new link
	eq(screen.party, [&"card.hero.a", &"card.hero.m1", &"", &""], "the owned member stays through a re-read")
	await _frames(3)   # let the link's deferred answers land before the game is freed


func test_a_refusal_without_a_code_just_frees_lock_in() -> void:
	var game := _game()
	var screen := await _open(game)
	screen._starting = true
	game.run_start_refused.emit({"status": 0, "errorCode": null, "title": "HttpRequestException"})
	await _frames(1)
	check(not screen._starting and not screen.get_node("%LockIn").disabled, "Lock in works again, no script error")


func test_arrows_leave_a_dialog_above_alone() -> void:
	var game := _game()
	var screen := await _open(game)
	var carousel: ClassCarousel3D = screen.get_node("%Carousel")
	var start := carousel.index
	game.ui.push(MODAL, load("res://game/dev/run_setup.tscn"))
	await _frames(2)
	var key := InputEventAction.new()
	key.action = &"ui_right"
	key.pressed = true
	screen._input(key)
	eq(carousel.index, start, "the ring stays while the modal is up")


func test_runsetup_clear_restores_the_content_root() -> void:
	var game := _game()
	await _frames(2)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	console.attach(game)
	game.set_content_root(GameMain.CONTENT_ROOTS[0])
	check((await console.execute("runsetup content " + FIXTURES))["ok"], "switch to the fixtures")
	eq(game.content_root, FIXTURES, "switched")
	await console.execute("runsetup clear")
	eq(game.content_root, GameMain.CONTENT_ROOTS[0], "clear goes back to the default root")
	eq(game.dev_run_setup, {}, "and empties the setup")


## Review 2026-11-19: effects ignore fog (fog tinted the clear edges of every additive quad: grey squares in the studio).
func test_effects_ignore_fog() -> void:
	var additive := StandardMaterial3D.new()
	additive.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	additive.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var copy := FxLayer.without_fog(additive) as BaseMaterial3D
	check(copy.disable_fog and not additive.disable_fog, "a transparent material gets a fog-free copy; the original is untouched")
	var opaque := StandardMaterial3D.new()
	eq(FxLayer.without_fog(opaque), opaque, "an opaque one keeps fog")
	if skip_in_export():
		return
	for path in ["beam_3d", "burst_3d", "glow_3d", "rays_3d", "rune_glyphs", "slash_3d", "material/particle_3d", "material/fresnel_overlay"]:
		var code := FileAccess.get_file_as_string("res://game/fx/shaders/%s.gdshader" % path)
		check(code.contains("fog_disabled"), "%s ignores fog" % path)


## Review 2026-11-19: a look effect on the upright look anchor measures its sockets (the floor) from the view, not from the bare
## anchor (which put floor rings at the cube's middle).
func test_the_look_anchor_is_measured_as_its_view() -> void:
	var view := UnitAnimator.new()
	view.upright_look_effect = true
	host.add_child(view)
	var anchor: Node3D = view._look_effect_host()
	check(anchor != view and anchor == view.look_anchor, "the effect plays on the look anchor")
	eq(FxAnchor.node3d(anchor).measured_node(), view, "measured as its view")
	var plain := Node3D.new()
	host.add_child(plain)
	eq(FxAnchor.node3d(plain).measured_node(), plain, "any other node is measured as itself")
	plain.free()
	view.free()



# --- Final review fixes (2026-11-19) -----------------------------------------------------------------------------------

func test_a_server_without_a_catalog_locks_nothing() -> void:
	var game := _game(_card_bridge([], {"catalogVersion": 0, "catalogHash": "", "cards": []}), true)
	var screen := await _open(game)
	eq(screen.states["card.hero.m2"], ClassPickModel.OPEN, "cards off or unseeded: the run start accepts any class")


func test_edits_before_the_answer_are_kept() -> void:
	var game := _game(_card_bridge(["card.hero.m1"]), true)
	await _frames(2)
	var screen := game.ui.push(MENU, load(SCREEN))
	await _frames(1)
	screen.apply_preset(_preset("early", ["card.hero.b"]))   # while the account is still being read
	for i in 120:
		if not screen.loading:
			break
		await _frames(1)
	await _frames(2)
	eq(screen.party[0], &"card.hero.b", "the player's preset stays when the answer lands")


func test_no_edits_while_starting() -> void:
	var game := _game()
	var screen := await _open(game)
	var before: Array = screen.party.duplicate()
	var index: int = screen.get_node("%Carousel").index
	screen._starting = true
	screen.turn(1)
	screen.toggle_selected()
	screen.remove_slot(0)
	eq([screen.party, screen.get_node("%Carousel").index], [before, index], "the party and the ring hold while Lock in starts")
	screen._starting = false


func test_a_repeated_preset_member_is_not_counted_missing() -> void:
	var states := {"a": ClassPickModel.OPEN, "b": ClassPickModel.OPEN}
	eq(ClassPickModel.apply_preset([&"a", &"a", &"b"], states, 4), {"party": [&"a", &"", &"b", &""], "missing": 0},
		"a repeat keeps one slot and counts as owned")


func test_a_pooled_particle_layer_gets_its_own_space_back() -> void:
	var layer := FxParticles3DLayer.new()
	layer.local_coords = false
	var node := layer.build()
	(node as GPUParticles3D).local_coords = true   # what the class pick does to a look effect on its ring
	layer.apply(node, {}, FxAnchor.screen(), FxQuality.HIGH, FxDefinition.new())
	check(not (node as GPUParticles3D).local_coords, "the next play uses the layer's own setting")
	node.free()


# --- Review round 2 fixes ------------------------------------------------------------------------------------------------

func test_a_repeated_locked_member_counts_once() -> void:
	eq(ClassPickModel.apply_preset([&"x", &"x", &"a"], {"x": ClassPickModel.LOCKED, "a": ClassPickModel.OPEN}, 4)["missing"], 1,
		"one class not owned, however often it is listed")


func test_an_empty_catalog_is_not_kept() -> void:
	var bridge := _card_bridge([], {"catalogVersion": 0, "catalogHash": "", "cards": []})
	var game := _game(bridge, true)
	var screen := await _open(game)
	check(game.server.card_catalog.is_empty(), "an empty catalog is read again next time, not kept on the link")
	bridge.answers["GetCardCatalog"] = [[true, _catalog()]]
	bridge.answers["GetCollection"] = [[true, _collection([])]]
	await screen.load_ownership()
	eq(screen.states["card.hero.m2"], ClassPickModel.LOCKED, "once seeded, the server's cards are enforced")
	await _frames(3)   # let the link's deferred answers land before the game is freed


func test_a_click_that_changes_nothing_keeps_the_saved_party_coming() -> void:
	var game := _game(_card_bridge(["card.hero.m1"]), true)
	await _frames(2)
	var screen := await _open(game)
	screen._restored = false   # as while the account is still being read
	screen.party = ClassPickModel.normalized([&"card.hero.a"], screen.max_party)
	screen.remove_slot(3)   # an empty slot
	check(not screen._restored, "nothing changed: the saved party may still come")
	screen.remove_slot(0)
	check(screen._restored, "a real change makes the party the player's")


func test_runsetup_clear_refuses_a_root_change_during_a_run() -> void:
	var game := _game()
	await _frames(2)
	eq(game.start_run(["fixture.character.knight"], "7", StringName(RUN)), "", "a run")
	game.set_content_root(FIXTURES, false)
	var refused := preload("res://game/dev/commands/runsetup.gd").clear(game)
	if game.content_root == GameMain.CONTENT_ROOTS[0]:
		eq(refused, "", "already on the default root: nothing to change")
	else:
		check(refused.contains("only from the menus"), "refused: " + refused)
