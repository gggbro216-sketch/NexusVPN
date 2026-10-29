class_name TestCase
extends RefCounted
## Minimal assertion helpers for the headless test runner (tests/run_tests.gd).

var failures: PackedStringArray = []
var skipped: PackedStringArray = []
var current_test := ""


## Marks the current test as skipped (reported separately, never as passed).
func skip(reason: String) -> void:
	skipped.append("%s: %s" % [current_test, reason])


func check(cond: bool, msg: String) -> bool:
	if not cond:
		failures.append("%s: %s" % [current_test, msg])
	return cond


func eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	if not same and typeof(actual) in [TYPE_INT, TYPE_FLOAT] and typeof(expected) in [TYPE_INT, TYPE_FLOAT]:
		same = float(actual) == float(expected)
	return check(same, "%s expected <%s> got <%s>" % [msg, str(expected), str(actual)])


func ok_result(r: Dictionary, msg: String = "") -> bool:
	return check(r.get("ok", false), "%s expected ok, got error: %s" % [msg, r.get("error", "")])


func err_result(r: Dictionary, contains: String = "", msg: String = "") -> bool:
	if not check(not r.get("ok", true), "%s expected an error, got ok" % msg):
		return false
	if contains != "":
		return check(str(r.get("error", "")).to_lower().contains(contains.to_lower()),
			"%s error <%s> should contain <%s>" % [msg, r.get("error", ""), contains])
	return true
