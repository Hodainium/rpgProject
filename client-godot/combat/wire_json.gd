## JSON for the wire contracts (Rpg.Contracts.Battle). Godot's JSON parser reads every number as a float, so a
## parsed-then-written value would come out as `1.0`, which the C# records' int fields reject. Everything Godot sends
## or stores as contract JSON goes through stringify(), which writes whole numbers as integers.
## Field order is kept (no key sorting), matching the C# records.
class_name WireJson
extends RefCounted


static func stringify(value: Variant) -> String:
	return JSON.stringify(normalize(value), "", false)


## Whole floats → int, recursively. Other values unchanged.
static func normalize(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			return int(value) if Fixed.is_whole(value) else value
		TYPE_ARRAY:
			var array: Array = []
			for item in value:
				array.append(normalize(item))
			return array
		TYPE_DICTIONARY:
			var dictionary := {}
			for key in value:
				dictionary[key] = normalize(value[key])
			return dictionary
	return value
