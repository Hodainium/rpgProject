## A list of FxListeners attached together (spec vfx-content-pass 3.2): "when this happens, play that", as one resource a
## screen or battle view attaches and that detaches with its node. Authored as data (presentation/demo/fx/battle_fx_rules.tres).
## Presentation only.
class_name FxRuleSet
extends Resource

@export var rules: Array[FxListener] = []


## Starts every rule for `owner`. The handles leave with the node (the listeners are owner-bound).
func attach(owner: Node) -> Array[GameplayMessageHandle]:
	var handles: Array[GameplayMessageHandle] = []
	for rule in rules:
		if rule != null:
			handles.append(rule.attach(owner))
	return handles
