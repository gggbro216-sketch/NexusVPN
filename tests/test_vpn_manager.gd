extends TestCase
## SingBoxManager state machine with FakeVpnBackend.

const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"

var _tree: SceneTree
var _fake: FakeVpnBackend
var _settings_backup := {}
var _states: Array = []
var _pid := ""


func setup(runner: Node) -> void:
	_tree = runner.get_tree()
	_settings_backup = Settings.export_data()
	Profiles.storage_path = "user://test_profiles_vpn.dat"
	Profiles.reset_storage()
	var r := Profiles.import_text("vless://%s@t.example.com:443?security=tls#Test" % UUID, "manual")
	_pid = r.added[0]
	Profiles.set_active(_pid)
	Settings.set_value("reconnect_base_delay_s", 1)
	Settings.set_value("reconnect_max_attempts", 2)
	Settings.set_value("url_test_timeout_s", 1)
	Settings.set_value("verify_connection", true)
	Settings.set_value("auto_reconnect", true)
	Settings.set_value("ip_check_enabled", false)
	SingBoxManager.state_changed.connect(_on_state)


func teardown() -> void:
	SingBoxManager.state_changed.disconnect(_on_state)
	await SingBoxManager.stop_vpn()
	SingBoxManager.set_backend(UnsupportedVpnBackend.new(Platform.bridge_error) if not Platform.has_vpn_backend() else AndroidVpnBackend.new(Platform.bridge))
	SingBoxManager._set_state(VpnState.State.DISCONNECTED, "")
	Profiles.reset_storage()
	Profiles.storage_path = ProfileStorage.DEFAULT_PATH
	Profiles.load_from_disk()
	Settings.import_data(_settings_backup)


func _on_state(s: int, _m: String) -> void:
	_states.append(s)


func _fresh() -> void:
	if SingBoxManager.is_active() or VpnState.is_busy(SingBoxManager.state):
		await SingBoxManager.stop_vpn()
	_fake = FakeVpnBackend.new(_tree)
	SingBoxManager.set_backend(_fake)
	SingBoxManager._set_state(VpnState.State.DISCONNECTED, "")
	_states.clear()


func _wait_state(target: int, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline:
		if SingBoxManager.state == target:
			return true
		await _tree.create_timer(0.05).timeout
	return false


func test_connect_success_is_verified() -> void:
	await _fresh()
	var r: Dictionary = await SingBoxManager.start_vpn()
	if not ok_result(r):
		return
	eq(SingBoxManager.state, VpnState.State.CONNECTED)
	check(VpnState.State.PREPARING in _states and VpnState.State.CONNECTING in _states, "went through preparing/connecting: %s" % str(_states))
	check(_fake.calls.has("url_test"), "connection verified through the proxy before CONNECTED")
	var p := Profiles.get_profile(_pid)
	eq(p.latency.method, "proxy")
	eq(int(p.latency.ms), 120)
	_fake.send_status(1000, 5000)
	await _tree.process_frame
	eq(int(SingBoxManager.get_statistics().down_total), 5000)
	check(History.has_open_session(), "session recorded")
	var again: Dictionary = await SingBoxManager.start_vpn()
	err_result(again, "уже")
	var s: Dictionary = await SingBoxManager.stop_vpn()
	ok_result(s)
	eq(SingBoxManager.state, VpnState.State.DISCONNECTED)
	check(not History.has_open_session(), "session closed")
	eq(int(History.sessions[-1].down_bytes), 5000)


func test_permission_denied() -> void:
	await _fresh()
	_fake.permission = false
	_fake.granted_on_request = false
	var r: Dictionary = await SingBoxManager.start_vpn()
	err_result(r, "разрешение")
	check(VpnState.State.REQUESTING_PERMISSION in _states, "requested permission")
	check(not _fake.calls.has("start"), "core not started without permission")
	eq(SingBoxManager.state, VpnState.State.ERROR)


func test_permission_granted_flow() -> void:
	await _fresh()
	_fake.permission = false
	var r: Dictionary = await SingBoxManager.start_vpn()
	ok_result(r)
	eq(SingBoxManager.state, VpnState.State.CONNECTED)


func test_unreachable_server_is_not_connected() -> void:
	await _fresh()
	_fake.probe_ms = -1
	var r: Dictionary = await SingBoxManager.start_vpn()
	err_result(r, "не отвечает")
	eq(SingBoxManager.state, VpnState.State.ERROR)
	check(not (VpnState.State.CONNECTED in _states), "never reported CONNECTED")
	check(_fake.calls.has("stop"), "core stopped after failed verification")
	eq(_fake.core_state, VpnState.Core.STOPPED)


func test_core_start_failure() -> void:
	await _fresh()
	_fake.core_fail_message = "bind: permission denied"
	var r: Dictionary = await SingBoxManager.start_vpn()
	err_result(r, "bind")
	eq(SingBoxManager.state, VpnState.State.ERROR)


func test_invalid_config_not_started() -> void:
	await _fresh()
	_fake.check_error = "unknown field"
	var r: Dictionary = await SingBoxManager.start_vpn()
	err_result(r, "unknown field")
	check(not _fake.calls.has("start"), "not started")


func test_auto_reconnect_after_crash() -> void:
	await _fresh()
	await SingBoxManager.start_vpn()
	_fake.crash("connection reset")
	await _tree.process_frame
	eq(SingBoxManager.state, VpnState.State.RECONNECTING)
	check(await _wait_state(VpnState.State.CONNECTED, 6.0), "reconnected, state=%d" % SingBoxManager.state)
	eq(_fake.calls.count("start"), 2)


func test_reconnect_gives_up() -> void:
	await _fresh()
	await SingBoxManager.start_vpn()
	_fake.core_fail_message = "server gone"
	_fake.crash("connection reset")
	check(await _wait_state(VpnState.State.ERROR, 12.0), "gave up with ERROR, state=%d" % SingBoxManager.state)
	check(_fake.calls.count("start") <= 1 + int(Settings.get_value("reconnect_max_attempts")), "bounded attempts: %d" % _fake.calls.count("start"))


func test_revoked_does_not_reconnect() -> void:
	await _fresh()
	await SingBoxManager.start_vpn()
	_fake.crash("revoked")
	await _tree.create_timer(1.5).timeout
	eq(SingBoxManager.state, VpnState.State.DISCONNECTED)
	eq(_fake.calls.count("start"), 1)


func test_network_loss_waits_for_network() -> void:
	await _fresh()
	await SingBoxManager.start_vpn()
	_fake.send_network(false)
	await _tree.process_frame
	eq(SingBoxManager.state, VpnState.State.CONNECTED, "stays connected; core recovers on its own")
	_fake.crash("network unreachable")
	await _tree.process_frame
	eq(SingBoxManager.state, VpnState.State.RECONNECTING)
	await _tree.create_timer(1.5).timeout
	eq(_fake.calls.count("start"), 1, "no restart while offline")
	_fake.send_network(true, "cellular")
	check(await _wait_state(VpnState.State.CONNECTED, 6.0), "reconnected after network returned")


func test_app_restart_adopts_running_core() -> void:
	await _fresh()
	await SingBoxManager.start_vpn()
	# Simulate a new UI process: new backend object seeing a running core.
	var b := FakeVpnBackend.new(_tree)
	b.core_state = VpnState.Core.STARTED
	b.info = {"profile_id": _pid, "profile_name": "Test"}
	SingBoxManager._set_state(VpnState.State.DISCONNECTED, "")
	SingBoxManager.set_backend(b)
	eq(SingBoxManager.state, VpnState.State.CONNECTED)
	eq(SingBoxManager.active_profile_id, _pid)
	_fake = b
	await SingBoxManager.stop_vpn()


func test_no_profile() -> void:
	await _fresh()
	Settings.set_value("active_profile_id", "")
	var r: Dictionary = await SingBoxManager.start_vpn()
	err_result(r, "сервер")
	Profiles.set_active(_pid)
