class_name FakeVpnBackend
extends VpnBackend
## Scriptable VpnBackend for SingBoxManager state-machine tests. Simulates the
## asynchronous native layer with timers; never claims to be a real VPN.

var tree: SceneTree
var permission := true
var granted_on_request := true
var check_error := ""
var start_error := ""            ## returned synchronously by start()
var core_fail_message := ""      ## core reports STOPPED with this message after start
var probe_ms := 120              ## -1 = URL test fails
var core_state := VpnState.Core.STOPPED
var calls: Array[String] = []
var info := {}


func _init(p_tree: SceneTree) -> void:
	tree = p_tree


func is_available() -> bool:
	return true


func core_version() -> String:
	return "fake"


func check_config(json: String) -> String:
	calls.append("check")
	var j := JsonUtil.parse(json)
	if not j.ok:
		return "bad json"
	return check_error


func has_permission() -> bool:
	return permission


func request_permission() -> void:
	calls.append("request_permission")
	await tree.create_timer(0.05).timeout
	permission = granted_on_request
	permission_result.emit(granted_on_request)


func start(_json: String, profile_id: String, profile_name: String) -> String:
	calls.append("start")
	if start_error != "":
		return start_error
	info = {"profile_id": profile_id, "profile_name": profile_name}
	_run_start()
	return ""


func _run_start() -> void:
	_set_core(VpnState.Core.STARTING, "")
	await tree.create_timer(0.1).timeout
	if core_fail_message != "":
		_set_core(VpnState.Core.STOPPED, core_fail_message)
	else:
		_set_core(VpnState.Core.STARTED, "")


func stop() -> void:
	calls.append("stop")
	_run_stop()


func _run_stop() -> void:
	if core_state == VpnState.Core.STOPPED:
		_set_core(VpnState.Core.STOPPED, "")
		return
	_set_core(VpnState.Core.STOPPING, "")
	await tree.create_timer(0.05).timeout
	_set_core(VpnState.Core.STOPPED, "")


## Simulates the core dying / the system revoking the VPN.
func crash(message: String) -> void:
	_set_core(VpnState.Core.STOPPED, message)


func _set_core(s: int, msg: String) -> void:
	core_state = s
	core_state_changed.emit(s, msg)


func get_core_info() -> Dictionary:
	var d := {"state": core_state, "message": "", "started_at": int(Time.get_unix_time_from_system() * 1000)}
	d.merge(info)
	return d


func url_test(group: String) -> String:
	calls.append("url_test")
	if core_state != VpnState.Core.STARTED:
		return "core not running"
	_emit_url(group)
	return ""


func _emit_url(group: String) -> void:
	await tree.create_timer(0.05).timeout
	if probe_ms > 0:
		url_test_received.emit({"group": group, "items": {"server": {"delay_ms": probe_ms, "time": int(Time.get_unix_time_from_system() * 1000)}}})


func send_status(up_total: int, down_total: int) -> void:
	status_received.emit({"up": 10, "down": 20, "up_total": up_total, "down_total": down_total, "connections": 3})


func send_network(available: bool, type: String = "wifi") -> void:
	network_changed.emit({"available": available, "type": type if available else "none", "changed_type": true})
