## Spec hash-id-lists 2.1: a one-to-one text encoding of plain data, for the run hash. Every value reads back to exactly one value:
## strings quoted and escaped (JSON), numbers bare, booleans and null as words, lists and dictionaries bracketed. Strings and
## StringNames encode alike on purpose (a restored snapshot turns ids back into StringNames and the rules compare them as equal),
## and a whole float encodes as its int (JSON-parsed data holds floats). Anything else is an error, written as `!<type>`, so a test,
## a report or the verifier fails loudly instead of hashing it ambiguously.
class_name RunCanonical
extends RefCounted

## Values refused so far in this process (push_error alone passes silently): the step runner turns a change into a runner error,
## the play report into one of its errors, and the tests check it.
static var failures: int = 0


static func encode(value: Variant) -> String:
	var parts := PackedStringArray()
	_write(value, parts)
	return "".join(parts)


static func _write(value: Variant, out: PackedStringArray) -> void:
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME:
			out.append(JSON.stringify(String(value)))
		TYPE_INT:
			out.append(str(value))
		TYPE_FLOAT:
			if is_finite(value) and value == floorf(value) and absf(value) < 9.0e15:
				out.append(str(int(value)))
			else:
				_refuse("a float that is not whole (%s)" % value, "float", out)
		TYPE_BOOL:
			out.append("true" if value else "false")
		TYPE_NIL:
			out.append("null")
		TYPE_ARRAY:
			out.append("[")
			var first := true
			for item in value:
				if not first:
					out.append(",")
				first = false
				_write(item, out)
			out.append("]")
		TYPE_DICTIONARY:
			# Keys by their text, never by StringName pointer (client and verifier intern names in different orders). A key is
			# encoded like any value, so a string key "1" and an int key 1 stay apart.
			var keys: Array = value.keys()
			# Fast path (spec 2.4's budget): a snapshot's keys are all Strings (StringNames alike), sorted natively. Any fixed order keeps the text one to
			# one (the keys are written out), so this order need not be the encoded one of the general path below.
			if keys.all(func(key: Variant) -> bool: return key is String or key is StringName):
				var names := PackedStringArray(keys)
				names.sort()
				out.append("{")
				for index in names.size():
					if index > 0:
						out.append(",")
					out.append(JSON.stringify(names[index]))
					out.append(":")
					_write(value[names[index]], out)
				out.append("}")
				return
			var named: Array = []
			for key in keys:
				named.append([encode(key), key])
			named.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])  # sort-ok: a[0] is the key's encoded String
			out.append("{")
			var first := true
			for pair in named:
				if not first:
					out.append(",")
				first = false
				out.append(pair[0])
				out.append(":")
				_write(value[pair[1]], out)
			out.append("}")
		_:
			_refuse("a %s" % type_string(typeof(value)), type_string(typeof(value)), out)


static func _refuse(what: String, type_name: String, out: PackedStringArray) -> void:
	failures += 1
	push_error("RunCanonical: %s has no canonical form" % what)
	out.append("!" + type_name)
