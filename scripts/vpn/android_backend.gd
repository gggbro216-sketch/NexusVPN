class_name AndroidVpnBackend
extends VpnBackend
## Android adapter: talks to the "NexusVpnBridge" Godot plugin which runs the
## sing-box core (libbox) inside an Android VpnService.
##
## Native signals carry JSON strings; they are decoded here. Signals are
## connected deferred so handlers always run on the Godot main thread.

var bridge: Object


func _init(p_bridge: Object) -> void:
	bridge = p_bridge
	var flags := Object.CONNECT_DEFERRED
	bridge.connect("core_state", _on_core_state, flags)
	bridge.connect("core_status", _on_core_status, flags)
	bridge.connect("core_logs", _on_core_logs, flags)
	bridge.connect("url_test_result", _on_url_test, flags)
	bridge.connect("latency_result", _on_latency, flags)
	bridge.connect("vpn_permission_result", _on_permission, flags)
	bridge.connect("network_changed", _on_network, flags)


func is_available() -> bool:
	return true


func core_version() -> String:
	return str(bridge.getCoreVersion())


func check_config(json: String) -> String:
	return str(bridge.checkConfig(json))


func has_permission() -> bool:
	return bool(bridge.isVpnPrepared())


func request_permission() -> void:
	bridge.requestVpnPermission()


func start(json: String, xray_json: String, profile_id: String, profile_name: String) -> String:
	return str(bridge.startVpn(json, xray_json, profile_id, profile_name))


func check_xray_config(json: String) -> String:
	return str(bridge.checkXrayConfig(json))


func xray_version() -> String:
	return str(bridge.getXrayVersion())


func stop() -> void:
	bridge.stopVpn()


func get_core_info() -> Dictionary:
	var j := JsonUtil.parse(str(bridge.getCoreInfo()))
	if j.ok and typeof(j.data) == TYPE_DICTIONARY:
		return j.data
	return super.get_core_info()


func url_test(group: String) -> String:
	return str(bridge.urlTest(group))


func start_latency_session(json: String, xray_json: String, group: String, timeout_ms: int) -> String:
	return str(bridge.startLatencySession(json, xray_json, group, timeout_ms))


func reset_network() -> void:
	bridge.resetNetwork()


func get_network_info() -> Dictionary:
	var j := JsonUtil.parse(str(bridge.getNetworkInfo()))
	return j.data if j.ok and typeof(j.data) == TYPE_DICTIONARY else super.get_network_info()


func supports_per_app() -> bool:
	return true


func _on_core_state(state: int, message: String) -> void:
	core_state_changed.emit(state, message)


func _on_core_status(json: String) -> void:
	var j := JsonUtil.parse(json)
	if j.ok and typeof(j.data) == TYPE_DICTIONARY:
		status_received.emit(j.data)


func _on_core_logs(json: String) -> void:
	var j := JsonUtil.parse(json)
	if j.ok and typeof(j.data) == TYPE_ARRAY:
		logs_received.emit(j.data)


func _on_url_test(json: String) -> void:
	var j := JsonUtil.parse(json)
	if j.ok and typeof(j.data) == TYPE_DICTIONARY:
		url_test_received.emit(j.data)


func _on_latency(json: String) -> void:
	var j := JsonUtil.parse(json)
	if j.ok and typeof(j.data) == TYPE_DICTIONARY:
		latency_session_finished.emit(j.data)
	else:
		latency_session_finished.emit({"ok": false, "error": "некорректный ответ ядра", "items": {}})


func _on_permission(granted: bool) -> void:
	permission_result.emit(granted)


func _on_network(json: String) -> void:
	var j := JsonUtil.parse(json)
	if j.ok and typeof(j.data) == TYPE_DICTIONARY:
		network_changed.emit(j.data)
