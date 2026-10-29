class_name VpnBackend
extends RefCounted
## Platform adapter interface between SingBoxManager and a native VPN layer.
## Implementations: [AndroidVpnBackend] (libbox inside VpnService) and
## [UnsupportedVpnBackend] (platforms without an implementation — never fakes a
## connection). Future desktop adapters implement the same contract.

## Native core state changed. state: VpnState.Core value; message: error text or "".
signal core_state_changed(state: int, message: String)
## Traffic counters: {up, down (bytes/s), up_total, down_total (bytes), connections, memory}.
signal status_received(status: Dictionary)
## Core log batch: Array of [level:int, message:String].
signal logs_received(entries: Array)
## URL test results for a group: {group: String, items: {tag: {delay_ms:int, time:int}}}.
signal url_test_received(result: Dictionary)
## Result of a standalone latency session: {ok, error, items: {tag: delay_ms}}.
signal latency_session_finished(result: Dictionary)
signal permission_result(granted: bool)
## {available: bool, type: "wifi"|"cellular"|"ethernet"|"other"|"none", metered: bool}
signal network_changed(info: Dictionary)


func is_available() -> bool:
	return false


func unavailable_reason() -> String:
	return "VPN недоступен на этой платформе"


func core_version() -> String:
	return ""


## Validates a config with the real core. Returns "" or the core's error.
func check_config(_json: String) -> String:
	return unavailable_reason()


func has_permission() -> bool:
	return false


func request_permission() -> void:
	permission_result.emit.call_deferred(false)


## Starts the VPN. [param _xray_json] is the Xray config when the profile runs
## through Xray (XrayBridge), else "". Returns "" if the start request was
## accepted; the outcome arrives through core_state_changed.
func start(_json: String, _xray_json: String, _profile_id: String, _profile_name: String) -> String:
	return unavailable_reason()


## Validates an Xray config with the bundled Xray. Returns "" or the error.
func check_xray_config(_json: String) -> String:
	return unavailable_reason()


func xray_version() -> String:
	return ""


func stop() -> void:
	pass


## {state: VpnState.Core, message, started_at (unix ms), profile_id, profile_name}
func get_core_info() -> Dictionary:
	return {"state": VpnState.Core.STOPPED, "message": "", "started_at": 0, "profile_id": "", "profile_name": ""}


func url_test(_group: String) -> String:
	return unavailable_reason()


func start_latency_session(_json: String, _xray_json: String, _group: String, _timeout_ms: int) -> String:
	return unavailable_reason()


func reset_network() -> void:
	pass


func get_network_info() -> Dictionary:
	return {"available": true, "type": "other", "metered": false}


func supports_per_app() -> bool:
	return false
