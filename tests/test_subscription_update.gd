extends TestCase
## Subscription download + merge against a local fixture HTTP server
## (tests/http_fixture_server.py). Uses an isolated profile database.

const PORT := 18765
const BASE := "http://127.0.0.1:18765"

var _pid := -1
var _settings_backup := {}
var _runner: Node


func setup(runner: Node) -> void:
	_runner = runner
	_settings_backup = Settings.export_data()
	Settings.set_value("sub_allow_http", true)
	SubscriptionUpdater.allow_private_for_tests = true
	Profiles.storage_path = "user://test_profiles_sub.dat"
	_wipe()
	Profiles.load_from_disk()
	_pid = OS.create_process("python3", [ProjectSettings.globalize_path("res://tests/http_fixture_server.py"), str(PORT)])
	# Wait for the server to accept connections.
	for i in 50:
		var peer := StreamPeerTCP.new()
		peer.connect_to_host("127.0.0.1", PORT)
		await runner.get_tree().create_timer(0.1).timeout
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break


func teardown() -> void:
	if _pid > 0:
		OS.kill(_pid)
	SubscriptionUpdater.allow_private_for_tests = false
	Settings.import_data(_settings_backup)
	_wipe()
	Profiles.storage_path = ProfileStorage.DEFAULT_PATH
	Profiles.load_from_disk()


func _wipe() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		var p: String = "user://test_profiles_sub.dat" + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _fetch(path: String) -> Dictionary:
	var u := SubscriptionUpdater.new()
	_runner.add_child(u)
	var r: Dictionary = await u.fetch(BASE + path, "test", true)
	u.queue_free()
	return r


func test_fetch_ok_and_redirect() -> void:
	var r := await _fetch("/sub/links")
	if ok_result(r):
		eq(SubscriptionParser.parse(r.body).profiles.size(), 3)
		check(r.headers.has("subscription-userinfo"), "headers parsed")
	var rr := await _fetch("/sub/redirect")
	if ok_result(rr, "redirect"):
		check(str(rr.final_url).ends_with("/sub/links"), "followed redirect")


func test_http_errors() -> void:
	err_result(await _fetch("/sub/404"), "404")
	err_result(await _fetch("/sub/big"), "большой")
	var empty := await _fetch("/sub/empty")
	ok_result(empty, "empty body is a successful HTTP response")
	err_result(SubscriptionParser.parse(empty.body), "empty")
	var html := await _fetch("/sub/html")
	err_result(SubscriptionParser.parse(html.body), "html")


func test_timeout() -> void:
	err_result(await _fetch("/sub/slow"), "время")


func test_refresh_merge_preserves_user_data() -> void:
	await _fetch("/set?v=1")
	var add := Subscriptions.add(BASE + "/sub/links", "Fixture")
	if not ok_result(add):
		return
	var r1: Dictionary = await Subscriptions.refresh(add.id)
	if not ok_result(r1, "first refresh"):
		return
	eq(r1.added, 3)
	var sub := Subscriptions.get_sub(add.id)
	eq(int(sub.count), 3)
	eq(int(sub.user_info.total), 1000)
	eq(str(sub.name), "Fixture", "user-given name wins over profile-title")
	var a := _by_server("a.example.com")
	var b := _by_server("b.example.com")
	Profiles.rename(a.id, "Мой сервер A")
	Profiles.set_favorite(b.id, true)
	var a_id := a.id
	var b_id := b.id
	await _fetch("/set?v=2")
	var r2: Dictionary = await Subscriptions.refresh(add.id)
	if not ok_result(r2, "second refresh"):
		return
	eq(r2.added, 1, "D added")
	eq(r2.removed, 1, "C removed")
	eq(r2.updated, 2, "A and B matched")
	var a2 := _by_server("a.example.com")
	var b2 := _by_server("b.example.com")
	eq(a2.id, a_id, "id stable")
	eq(a2.name, "Мой сервер A", "user rename kept")
	eq(b2.id, b_id)
	eq(b2.favorite, true, "favourite kept")
	eq(b2.name, "Server B (new name)", "provider rename applied when user did not rename")
	check(_by_server("c.example.com") == null, "C removed")
	check(_by_server("d.example.com") != null, "D added")


func test_failed_refresh_keeps_profiles() -> void:
	await _fetch("/set?v=1")
	var add := Subscriptions.add(BASE + "/sub/links?x=2", "Fixture2")
	if not ok_result(add):
		return
	await Subscriptions.refresh(add.id)
	var before := Profiles.query("", "sub:" + add.id).size()
	check(before > 0, "has profiles")
	Subscriptions.update_fields(add.id, {"url": BASE + "/sub/404"})
	var r: Dictionary = await Subscriptions.refresh(add.id)
	err_result(r, "404")
	eq(Profiles.query("", "sub:" + add.id).size(), before, "profiles kept after HTTP error")
	Subscriptions.update_fields(add.id, {"url": BASE + "/sub/html"})
	err_result(await Subscriptions.refresh(add.id), "html")
	eq(Profiles.query("", "sub:" + add.id).size(), before, "profiles kept after bad content")
	check(str(Subscriptions.get_sub(add.id).last_error) != "", "error recorded")


func _by_server(host: String) -> ProfileModel:
	for p in Profiles.get_all():
		if p.server == host:
			return p
	return null
