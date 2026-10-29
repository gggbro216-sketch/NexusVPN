extends Node
## Headless test runner. Run with:
##   godot --headless --path . res://tests/run_tests.tscn
## Exit code 0 = all passed. Each tests/test_*.gd file extends TestCase and
## every method starting with "test_" is executed (awaited if it is a coroutine).
## Optional env NEXUS_TEST_FILTER=<substring> limits which files run.

const TEST_DIR := "res://tests"


const TIMEOUT_S := 600.0


func _ready() -> void:
	# Watchdog: never hang CI.
	get_tree().create_timer(TIMEOUT_S).timeout.connect(func():
		print("TIMEOUT: test run exceeded %ds" % TIMEOUT_S)
		get_tree().quit(2))
	await get_tree().process_frame
	var compile_errors := _compile_all("res://scripts") + _compile_all("res://scenes") + _compile_all("res://addons")
	if compile_errors > 0:
		print("%d script(s) failed to compile" % compile_errors)
		get_tree().quit(1)
		return
	var filter := OS.get_environment("NEXUS_TEST_FILTER")
	var total := 0
	var failed := 0
	var files := DirAccess.get_files_at(TEST_DIR)
	files.sort()
	for f in files:
		if not (f.begins_with("test_") and f.ends_with(".gd")) or f == "test_case.gd":
			continue
		if filter != "" and not f.contains(filter):
			continue
		var script: GDScript = load(TEST_DIR + "/" + f)
		if script == null or not script.can_instantiate():
			print("FAIL  %s: could not load script" % f)
			failed += 1
			continue
		var inst: TestCase = script.new()
		if inst.has_method("setup"):
			await inst.setup(self)
		for m in script.get_script_method_list():
			var name: String = m.name
			if not name.begins_with("test_"):
				continue
			total += 1
			inst.current_test = "%s::%s" % [f.get_basename(), name]
			var before := inst.failures.size()
			await inst.call(name)
			if inst.failures.size() > before:
				failed += 1
				print("FAIL  " + inst.current_test)
				for i in range(before, inst.failures.size()):
					print("      - " + inst.failures[i])
			else:
				print("ok    " + inst.current_test)
		if inst.has_method("teardown"):
			await inst.teardown()
	print("\n%d tests, %d failed" % [total, failed])
	get_tree().quit(1 if failed > 0 else 0)


## Loads every .gd file below [param dir] so parse errors fail the run.
func _compile_all(dir: String) -> int:
	var errors := 0
	if not DirAccess.dir_exists_absolute(dir):
		return 0
	for sub in DirAccess.get_directories_at(dir):
		errors += _compile_all(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			var s: GDScript = load(dir.path_join(f))
			if s == null or not s.can_instantiate():
				print("COMPILE FAIL  " + dir.path_join(f))
				errors += 1
	return errors
