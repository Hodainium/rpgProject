## Spec combat-replay-core "Test runner": catches every error raised while the tests run, so none passes silently.
## A GDScript runtime error (invalid access, bad call…) only aborts the function it happened in and the caller goes on
## with a default value; without this the test would still report ok. Kept: script errors and engine errors
## (ERR_FAIL… in C++, e.g. a missing node). Ignored: warnings, and push_error(), which system code uses on purpose
## (RunController's runner errors; their tests check the returned error instead).
## Installed with OS.add_logger() by run_tests.gd; the logger may be called from any thread.
class_name TestErrorLog
extends Logger

var _mutex := Mutex.new()
var _errors: Array[String] = []


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
		error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING or function == "push_error":
		return
	var text := "%s: %s" % ["script error" if error_type == ERROR_TYPE_SCRIPT else "engine error",
		code if rationale == "" else "%s (%s)" % [rationale, code]]
	text += " at %s:%d" % [file, line]
	for backtrace in script_backtraces:
		if backtrace.get_frame_count() > 0:
			var frame := "%s:%d" % [backtrace.get_frame_file(0), backtrace.get_frame_line(0)]
			if frame != "%s:%d" % [file, line]:
				text += " (in %s)" % frame  # an engine error: the script line that caused it
			break
	_mutex.lock()
	_errors.append(text)
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass


## The errors caught since the last take(), oldest first; the log is emptied.
func take() -> Array[String]:
	_mutex.lock()
	var taken := _errors.duplicate()
	_errors.clear()
	_mutex.unlock()
	return taken
