## Spec gameplay-messages 2.2 (M3): the client-only bridge from a shown battle's signals to Message.Battle.* verbs.
## GameMain attaches one to each battle it fights; the replay runner, the trace runner and the verifier never create
## one, and combat/ is unchanged, so the battle kernel never broadcasts. It only reads: names come from the units'
## definitions and go into the message's data (instigatorName, targetName) so listeners need no battle reference.
class_name BattleMessages
extends RefCounted


var _battle: Battle
var _encounter: StringName
var _router: GameplayMessageRouter


## Connects to `battle` (fought for `encounter_id`) and broadcasts Message.Battle.Started.
func attach(battle: Battle, encounter_id: StringName, router: GameplayMessageRouter) -> void:
	_battle = battle
	_encounter = encounter_id
	_router = router
	# Spec vfx-content-pass: the tags are the hit's Hit.* tags plus its Damage.Type.* tags.
	battle.damage_dealt.connect(func(source, target, amount, hit_tags):
		_send(GameplayMessageRouter.BATTLE_DAMAGE, &"Verb.Damage", source, target, amount, hit_tags))
	battle.hp_changed.connect(func(unit, delta, cause_tags):
		_send(GameplayMessageRouter.BATTLE_HP_CHANGED, &"Verb.Damage" if delta < 0 else &"Verb.Heal", &"", unit,
			absi(delta), cause_tags))
	battle.unit_broken.connect(func(unit, by):
		_send(GameplayMessageRouter.BATTLE_BROKEN, &"Verb.Break", by, unit))
	battle.unit_recovered.connect(func(unit):
		_send(GameplayMessageRouter.BATTLE_RECOVERED, &"Verb.Recover", &"", unit))
	battle.unit_downed.connect(func(unit, by):
		_send(GameplayMessageRouter.BATTLE_DOWNED, &"Verb.Down", by, unit))
	battle.one_more_started.connect(func(unit):
		_send(GameplayMessageRouter.BATTLE_ONE_MORE, &"Verb.OneMore", unit, unit))
	battle.interrupt_started.connect(func(unit, ability_tag):
		_send(GameplayMessageRouter.BATTLE_INTERRUPT, &"Verb.Interrupt", unit, &"", 0, [ability_tag],
			{"abilityName": AbilityName.of_tag(_battle.unit_by_id(unit), ability_tag)}))
	# magnitude: the phase entered, counted from 1.
	battle.phase_changed.connect(func(unit, phase):
		_send(GameplayMessageRouter.BATTLE_PHASE, &"Verb.Phase", unit, unit, phase + 1))
	battle.status_resisted.connect(func(source, target, effect_path: String):
		_send(GameplayMessageRouter.BATTLE_RESISTED, &"Verb.Resist", source, target, 0, [],
			{"status": effect_path.get_file().get_basename().capitalize()}))
	battle.damage_drained.connect(func(source, target, amount, tags):
		_send(GameplayMessageRouter.BATTLE_DRAINED, &"Verb.Drain", source, target, amount, tags))
	battle.turn_skipped.connect(func(unit):
		_send(GameplayMessageRouter.BATTLE_TURN_SKIPPED, &"Verb.Skip", unit, unit))
	# Spec ff7-ui 2.2: "X used Y" for the battle feed; tags are the ability's asset tags (an ult carries
	# Ability.Type.Ultimate, so a feed rule can leave ults to Message.Battle.Interrupt).
	battle.ability_activated.connect(func(unit, ability_tag, target):
		var actor := _battle.unit_by_id(unit)
		var ability := actor.ability_by_tag(ability_tag) if actor != null else null
		_send(GameplayMessageRouter.BATTLE_ABILITY_USED, &"Verb.Use", unit, target, 0,
			ability.asset_tags if ability != null else [], {"abilityName": AbilityName.of_tag(actor, ability_tag)}))
	battle.trigger_activated.connect(func(unit, ability_tag, event_tag):
		_send(GameplayMessageRouter.BATTLE_TRIGGER, &"Verb.Use", unit, unit, 0, [ability_tag, event_tag]))
	battle.unit_died.connect(func(unit):
		_send(GameplayMessageRouter.BATTLE_UNIT_DIED, &"Verb.Die", &"", unit))
	battle.battle_ended.connect(func(outcome: String, _hash):
		_send(GameplayMessageRouter.BATTLE_ENDED, &"Verb.Win" if outcome == Battle.VICTORY else &"Verb.Lose", &"",
			_encounter, 0, [], {"outcome": outcome}))
	_send(GameplayMessageRouter.BATTLE_STARTED, &"Verb.Start", &"", _encounter)


func _send(channel: StringName, verb: StringName, instigator: StringName, target: StringName, amount: int = 0,
		tags: Array = [], extras: Dictionary = {}) -> void:
	if _router == null or not is_instance_valid(_battle):
		return
	var data := extras.duplicate()
	if instigator != &"":
		data["instigatorName"] = _name(instigator)
	if target != &"" and target != _encounter:
		data["targetName"] = _name(target)
	_router.broadcast(channel, VerbMessage.make(verb, instigator, target, amount, tags, data))


func _name(unit_id: StringName) -> String:
	var unit := _battle.unit_by_id(unit_id)
	if unit == null or unit.definition == null:
		return String(unit_id)
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
