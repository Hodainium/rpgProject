## Test probe for spec ui-framework: a UIScreen that records every call the UIManager makes.
extends UIScreen

var calls: Array[String] = []
var consume_back: bool = false


func bind(_context: UIContext) -> void:
	calls.append("bind")


func on_pushed(payload: Dictionary) -> void:
	calls.append("pushed:%s" % payload.get("id", ""))


func on_activated() -> void:
	calls.append("activated")


func on_deactivated() -> void:
	calls.append("deactivated")


func handles_back() -> bool:
	return consume_back
