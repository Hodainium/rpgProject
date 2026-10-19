## How content code (ExecCalcs, brains) reaches the battle it runs in, without autoloads or static state,
## so several battles can run one after another in one process.
class_name BattleContext
extends RefCounted


## The Battle that owns this node (a unit, its ASC, or anything below them), or null.
static func battle_for(node: Node) -> Battle:
	var current := node
	while current != null:
		if current is Battle:
			return current
		current = current.get_parent()
	return null


## The battle's single seeded RNG. Combat draws from nothing else.
static func rng_for(node: Node) -> RandomNumberGenerator:
	var battle := battle_for(node)
	assert(battle != null, "BattleContext.rng_for: node is not inside a Battle")
	return battle.rng


## The CombatASC of the unit that applied a spec (its instigator).
static func source_asc(spec: GameplayEffectSpec) -> CombatASC:
	if spec.context == null or spec.context.instigator == null:
		return null
	return spec.context.instigator.get_node_or_null("AbilitySystemComponent") as CombatASC
