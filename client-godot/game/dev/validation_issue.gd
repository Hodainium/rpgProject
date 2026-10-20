## One content problem found by ContentValidator (spec dev-tools 3.7).
class_name ValidationIssue
extends RefCounted

const ERROR: String = "error"
const WARNING: String = "warning"

var severity: String
## Stable code, e.g. "dangling_ref" (the table in spec dev-tools 3.7).
var code: String
## Resource path, plus "::field[index]" where it helps.
var path: String
var message: String


func _init(issue_severity: String, issue_code: String, issue_path: String, issue_message: String) -> void:
	severity = issue_severity
	code = issue_code
	path = issue_path
	message = issue_message


func is_error() -> bool:
	return severity == ERROR


func _to_string() -> String:
	return "%s %s %s: %s" % [severity.to_upper(), code, path, message]
