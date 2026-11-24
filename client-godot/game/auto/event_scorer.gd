## Spec event-pass 2.8: how the bots pick an event choice. Class choices (Choice.Class) come first for every policy; the
## smart policy then scores the choices' Choice.* tags against the run's state, the others pick at random. Every draw is
## on the bots' own stream dev/event/<floor>/<cell>/<log size>, never a run stream, so the run only sees an ordinary
## logged choose. The weights below are bot code, not game balance.
class_name EventScorer
extends RefCounted

const CLASS_TAG: StringName = &"Choice.Class"
const LEAVE_TAG: StringName = &"Choice.Leave"
const GAMBLE_TAG: StringName = &"Choice.Gamble"
const FIGHT_TAG: StringName = &"Choice.Fight"

const POLICY_RANDOM: String = "random"
const POLICY_SMART: String = "smart"

## What a gain is worth (Heal is scaled by the party's missing HP).
const GAINS: Dictionary = {
	&"Choice.Gain.Item": 30, &"Choice.Gain.BossItem": 60, &"Choice.Gain.Armor": 25, &"Choice.Gain.Coins": 10,
	&"Choice.Gain.Keys": 15, &"Choice.Gain.Heal": 40, &"Choice.Gain.Xp": 15, &"Choice.Gain.Level": 25,
	&"Choice.Gain.Reveal": 5, &"Choice.Gain.Chest": 20,
}
## Every Choice.* tag (spec event-pass 2.8), for sync_tags' system-tag check: a typo in content or code fails it.
const ALL_TAGS: Array[StringName] = [
	&"Choice.Gain.Item", &"Choice.Gain.BossItem", &"Choice.Gain.Armor", &"Choice.Gain.Coins", &"Choice.Gain.Keys",
	&"Choice.Gain.Heal", &"Choice.Gain.Xp", &"Choice.Gain.Level", &"Choice.Gain.Reveal", &"Choice.Gain.Chest",
	&"Choice.Cost.Coins", &"Choice.Cost.Keys", &"Choice.Cost.Hp", &"Choice.Cost.Item", &"Choice.Cost.Life",
	&"Choice.Cost.Curse", &"Choice.Fight", &"Choice.Gamble", &"Choice.Leave", &"Choice.Class",
]
## Content tags the event pass's code reads (spec event-pass 2.4, 2.6).
const CONTENT_TAGS: Array[StringName] = [&"Encounter.Event", &"Item.Boon", &"Item.Curse"]
## A choice with this score is never taken while another is enabled.
const REFUSED: int = -100000


## The choice index the bot takes among the enabled `indices` of the current page (-1 when none).
static func pick(run: RunController, indices: Array, policy: String) -> int:
	if indices.is_empty():
		return -1
	var page := run.current_page()
	var pool: Array = indices.filter(func(index: int) -> bool: return page.choices[index].tags.has(CLASS_TAG))
	if pool.is_empty():
		pool = indices
	var rng := RunSeeds.rng(run.state.run_seed, "dev/event/%d/%d/%d" % [run.state.floor_index,
		int(run.state.event.get("cell", run.state.current_cell)), run.run_log.size()])
	if policy != POLICY_SMART:
		return pool[rng.randi_range(0, pool.size() - 1)]
	var best: Array = []
	var best_score := REFUSED - 1
	for index in pool:
		var value := score(run, page.choices[index])
		if value > best_score:
			best_score = value
			best = [index]
		elif value == best_score:
			best.append(index)
	return best[rng.randi_range(0, best.size() - 1)]


## The smart policy's score of `choice` (Leave and untagged choices score 0).
static func score(run: RunController, choice: EventChoice) -> int:
	var tags := choice.tags
	var share := party_hp_share(run)  # x10000
	var alive := run.state.party.filter(func(member: Dictionary) -> bool: return member["alive"]).size()
	var gains := 0
	for tag in tags:
		if tag == &"Choice.Gain.Heal":
			gains += GAINS[tag] * (10000 - share) / 10000
		elif GAINS.has(tag):
			gains += GAINS[tag]
	if tags.has(GAMBLE_TAG):
		gains /= 2
	var costs := 0
	if tags.has(&"Choice.Cost.Life"):
		if not tags.has(&"Choice.Gain.BossItem") or alive < 3:
			return REFUSED
		costs += 40
	if tags.has(&"Choice.Cost.Hp") or tags.has(GAMBLE_TAG):
		# User, 2026-11-22: who pays and how much, read from the outcomes (this choice's and every page it can lead to,
		# each outcome of a gamble apart): a member who would not survive refuses the choice; otherwise the cost
		# follows the hardest-hit member, not the party's average.
		var risk := hp_risk(run, choice)
		if risk["kills"]:
			return REFUSED
		if risk["hurts"]:
			var lowest: int = risk["lowest"]
			costs += 10 if lowest >= 7000 else (25 if lowest >= 4000 else 60)
		elif tags.has(&"Choice.Cost.Hp"):
			costs += 10 if share >= 7000 else (25 if share >= 4000 else 60)  # a cost the outcomes don't show
	if tags.has(FIGHT_TAG):
		costs += 10 if share >= 6000 else 40
	if tags.has(&"Choice.Cost.Coins"):
		costs += 20 if run.state.coins < 30 else 10
	if tags.has(&"Choice.Cost.Keys"):
		costs += 25 if run.state.keys <= 1 else 12
	if tags.has(&"Choice.Cost.Item"):
		costs += 20
	if tags.has(&"Choice.Cost.Curse"):
		costs += 25
	return gains - costs


## What a choice's HP losses would do (user, 2026-11-22): {"hurts": any member loses HP, "kills": a member would not
## survive an HP loss (a slay is Choice.Cost.Life's rule, not counted here), "lowest": the hardest-hit member's HP share
## afterwards x10000}. The choice's outcomes, then each page it leads to (a gamble's pages one by one, the worst counts);
## a RANDOM target is the member it would hurt most. Heals are left out, so the estimate errs on the careful side.
static func hp_risk(run: RunController, choice: EventChoice) -> Dictionary:
	var event := run.current_event()
	var stats := BotCache.party_stats(run)
	var paths: Array = []  # each: the outcomes one way through the choice
	var direct: Array = choice.outcomes.duplicate()
	var branches: Array = []
	for outcome in choice.outcomes:
		if outcome is GoToPage:
			branches.append([outcome.page])
		elif outcome is GoToRandomPage:
			branches.append(outcome.pages)
	if branches.is_empty():
		paths.append(direct)
	for pages in branches:
		for index in pages:
			var path := direct.duplicate()
			if event != null and index >= 0 and index < event.pages.size() and event.pages[index] != null:
				path.append_array(event.pages[index].on_enter)
			paths.append(path)
	var result := {"hurts": false, "kills": false, "lowest": 10000}
	for path in paths:
		var hp := {}
		for member in run.state.party:
			if member["alive"]:
				hp[int(member["slot"])] = int(member["hp"])
		for outcome in path:
			var effect: GameplayEffect = outcome.effect if (outcome is ApplyMemberEffect or outcome is ApplyPartyEffect) else null
			if effect == null:
				continue
			for slot in _targets(run, outcome, hp):
				var loss := _hp_loss(effect, int(stats.get(slot, {}).get(BattleUnit.MAX_HP, 0)))
				if loss <= 0:
					continue  # a heal, or a slay (Choice.Cost.Life decides that one)
				result["hurts"] = true
				hp[slot] = int(hp[slot]) - loss
				if int(hp[slot]) <= 0:
					result["kills"] = true
		for slot in hp:
			var max_hp := int(stats.get(slot, {}).get(BattleUnit.MAX_HP, 0))
			if max_hp > 0:
				result["lowest"] = mini(result["lowest"], maxi(int(hp[slot]), 0) * 10000 / max_hp)
	return result


## The slots an outcome would hit, by the game's own targeting; RANDOM and LOWEST_HP: the member with the least HP left.
static func _targets(run: RunController, outcome: RunOutcome, hp: Dictionary) -> Array:
	var living: Array = hp.keys()
	living.sort()  # sort-ok: party slots are ints
	if living.is_empty():
		return []
	if outcome is ApplyPartyEffect:
		return living
	var weakest: int = living[0]
	for slot in living:
		if int(hp[slot]) < int(hp[weakest]):
			weakest = slot
	match outcome.target:
		ApplyMemberEffect.Target.ALL:
			return living
		ApplyMemberEffect.Target.FIRST:
			return [living[0]]
		ApplyMemberEffect.Target.SLOT:
			return [outcome.slot] if hp.has(outcome.slot) else []
		ApplyMemberEffect.Target.CHARACTER:
			var found := run.state.member_slot(outcome.character.id) if outcome.character != null else 0
			return [found] if hp.has(found) else []
	return [weakest]  # RANDOM (the worst case) and LOWEST_HP


## How much HP `effect` takes from a member with `max_hp` (stored x100): a percent of max HP (an execution's
## percent_x100) or a flat hp change (CombatModifier ADD); 0 for a heal, a slay or anything it cannot read.
static func _hp_loss(effect: GameplayEffect, max_hp: int) -> int:
	for execution in effect.executions:
		if execution != null and "percent_x100" in execution and (not "attribute" in execution or str(execution.get("attribute")) == "hp"):
			var percent := int(execution.get("percent_x100"))
			return -max_hp * percent / 10000 if percent < 0 else 0
	for modifier in effect.modifiers:
		if modifier == null or modifier.attribute_name != "hp" or modifier.operation != GameplayEffectModifier.Operation.ADD:
			continue
		var amount := int(modifier.get("value_x100")) if "value_x100" in modifier else int(modifier.magnitude)
		return -amount if amount < 0 else 0
	return 0


## The living members' average HP share x10000 (10000 when nobody's max HP is known).
static func party_hp_share(run: RunController) -> int:
	var stats := BotCache.party_stats(run)
	var total := 0
	var counted := 0
	for member in run.state.party:
		if not member["alive"]:
			continue
		var max_hp := int(stats.get(member["slot"], {}).get(BattleUnit.MAX_HP, 0))
		if max_hp > 0:
			total += int(member["hp"]) * 10000 / max_hp
			counted += 1
	return total / counted if counted > 0 else 10000
