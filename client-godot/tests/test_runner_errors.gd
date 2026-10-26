## Spec combat-replay-core "Test runner": errors never pass silently. Each test here causes an error on purpose and
## declares it with expect_error(); without that declaration the runner would fail the test (TestErrorLog). If capture
## broke, the expectation would go unmet and these tests would fail instead.
extends TestCase


static func _read_missing(values: Dictionary) -> Variant:
	return values.nope


## A GDScript runtime error only aborts the function it happens in; the caller goes on with null.
func test_runner_catches_script_errors() -> void:
	expect_error("Invalid access to property or key 'nope'")
	eq(_read_missing({}), null, "the failed function returns null and the test goes on")


## An engine error (ERR_FAIL in C++): a node that isn't there.
func test_runner_catches_engine_errors() -> void:
	expect_error("Node not found")
	check(host.get_node("NoSuchNode/Anywhere") == null, "get_node fails")


## An error after an await (a coroutine resumed later) still belongs to this test.
func test_runner_catches_errors_after_await() -> void:
	expect_error("Invalid access to property or key 'nope'")
	await host.get_tree().process_frame
	_read_missing({})


## push_error() is deliberate logging (RunController's runner errors) and never fails a test.
func test_runner_allows_push_error() -> void:
	push_error("test_runner_allows_push_error: deliberate")
	check(true, "")
