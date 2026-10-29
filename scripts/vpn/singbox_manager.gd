extends Node
## Autoload "SingBoxManager": the single entry point the UI uses to control the
## sing-box core.
##
## Public API (all non-blocking; long operations are coroutines — use await):
##   start_vpn(profile_id := "") -> Dictionary   {ok, error}. Resolves when the
##       connection is verified (CONNECTED) or failed (ERROR). Uses the active
##       profile when profile_id is empty.
##   stop_vpn() -> Dictionary                    {ok, error}. Resolves when stopped.
##   restart_vpn() -> Dictionary                 stop + start with the same profile.
##   switch_server(profile_id) -> Dictionary     selects profile; reconnects if active.
##   get_status() -> Dictionary                  snapshot: state, label, message,
##       profile_id, profile_name, connected_since, exit_ip, exit_country, core_version.
##   get_logs(level := Log.Level.DEBUG) -> Array[Dictionary]  core log entries.
##   get_statistics() -> Dictionary              {up, down, up_total, down_total,
##       connections, source, updated_at}. Real counters from the core only.
##   test_connection(profile_id) -> Dictionary   latency test (see Latency autoload).
##   validate_profile(profile_id) -> Dictionary  {ok, error, warnings} incl. core check.
##
## Signals: state_changed(state, message), stats_updated(stats), ip_info_updated(info).

signal state_changed(state: int, message: String)
signal stats_updated(stats: Dictionary)
signal ip_info_updated(info: Dictionary)

const START_TIMEOUT_S := 30.0
const STOP_TIMEOUT_S := 12.0
const PERMISSION_TIMEOUT_S := 180.0
const VERIFY_ATTEMPTS := 3
const MAX_RECONNECT_DELAY_S := 60.0

var backend: VpnBackend
var state: int = VpnState.State.DISCONNECTED
var state_message := ""
var active_profile_id := ""
var active_profile_name := ""
var connected_since := 0          ## unix seconds, 0 if not connected
var last_error := ""
var exit_ip := ""
var exit_country := ""
var last_config_warnings := PackedStringArray()

var _stats := {"up": 0, "down": 0, "up_total": 0, "down_total": 0, "connections": 0, "source": "", "updated_at": 0}
var _core_state: int = VpnState.Core.STOPPED
var _core_message := ""
var _op := 0                      ## increments to cancel stale async flows
var _user_stop := false
var _reconnect_attempt := 0
var _reconnect_timer: Timer
var _network_available := true
var _waiting_for_network := false
var _url_results := {}
var _ip_checker: ConnectivityChecker


func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timer)
	add_child(_reconnect_timer)
	_ip_checker = ConnectivityChecker.new()
	add_child(_ip_checker)
	if Platform.has_vpn_backend():
		set_backend(AndroidVpnBackend.new(Platform.bridge))
	else:
		set_backend(UnsupportedVpnBackend.new(Platform.bridge_error))


## Replaces the backend (used at startup and by tests).
func set_backend(b: VpnBackend) -> void:
	if backend != null:
		for sig in ["core_state_changed", "status_received", "logs_received", "url_test_received", "network_changed"]:
			for c in backend.get_signal_connection_list(sig):
				backend.disconnect(sig, c.callable)
	backend = b
	backend.core_state_changed.connect(_on_core_state)
	backend.status_received.connect(_on_status)
	backend.logs_received.connect(_on_logs)
	backend.url_test_received.connect(_on_url_test)
	backend.network_changed.connect(_on_network_changed)
	_reset_runtime()
	_adopt_running_core()


func is_available() -> bool:
	return backend != null and backend.is_available()


func unavailable_reason() -> String:
	return backend.unavailable_reason() if backend else "backend missing"


func is_active() -> bool:
	return VpnState.is_active(state)


func core_version() -> String:
	return backend.core_version() if is_available() else ""


# --- public API ----------------------------------------------------------------

func start_vpn(profile_id: String = "") -> Dictionary:
	if VpnState.is_busy(state) or state == VpnState.State.CONNECTED:
		return {"ok": false, "error": "VPN уже %s" % VpnState.label(state).to_lower()}
	if not is_available():
		_set_state(VpnState.State.ERROR, unavailable_reason())
		return {"ok": false, "error": unavailable_reason()}
	var profile := _resolve_profile(profile_id)
	if profile == null:
		var msg := "сначала добавьте и выберите сервер"
		_set_state(VpnState.State.ERROR, msg)
		return {"ok": false, "error": msg}
	_reconnect_attempt = 0
	_reconnect_timer.stop()
	return await _connect_flow(profile, false)


func stop_vpn() -> Dictionary:
	_reconnect_timer.stop()
	_waiting_for_network = false
	if _core_state == VpnState.Core.STOPPED and state != VpnState.State.CONNECTING:
		# Nothing runs natively (idle, error, or still preparing / waiting for
		# permission): cancel any pending connect flow.
		_op += 1
		_set_state(VpnState.State.DISCONNECTED, "")
		return {"ok": true, "error": ""}
	_op += 1
	var op := _op
	_user_stop = true
	_set_state(VpnState.State.STOPPING, "")
	backend.stop()
	var r := await _wait_core([VpnState.Core.STOPPED], STOP_TIMEOUT_S, op)
	_user_stop = false
	_finish_session("")
	if r.timeout:
		_set_state(VpnState.State.ERROR, "ядро не остановилось вовремя")
		return {"ok": false, "error": "stop timeout"}
	if op == _op:
		_set_state(VpnState.State.DISCONNECTED, "")
	return {"ok": true, "error": ""}


func restart_vpn() -> Dictionary:
	var pid := active_profile_id if active_profile_id != "" else str(Settings.get_value("active_profile_id"))
	if is_active() or VpnState.is_busy(state):
		await stop_vpn()
	return await start_vpn(pid)


func switch_server(profile_id: String) -> Dictionary:
	Profiles.set_active(profile_id)
	if is_active():
		Log.info("vpn", "switching server, reconnecting")
		return await restart_vpn()
	return {"ok": true, "error": ""}


func get_status() -> Dictionary:
	return {
		"state": state, "label": VpnState.label(state), "message": state_message,
		"profile_id": active_profile_id, "profile_name": active_profile_name,
		"connected_since": connected_since, "exit_ip": exit_ip, "exit_country": exit_country,
		"core_version": core_version(), "available": is_available(),
		"network_available": _network_available, "last_error": last_error,
	}


func get_logs(level: int = Log.Level.DEBUG) -> Array[Dictionary]:
	return Log.get_entries(level, Log.SOURCE_CORE)


func get_statistics() -> Dictionary:
	return _stats.duplicate()


func test_connection(profile_id: String) -> Dictionary:
	return await Latency.test_profiles([profile_id])


## Builds the config for a profile and validates it with the real core.
func validate_profile(profile_id: String) -> Dictionary:
	var p := Profiles.get_profile(profile_id)
	if p == null:
		return {"ok": false, "error": "профиль не найден", "warnings": PackedStringArray()}
	var built := ConfigBuilder.build_vpn_config(p, Settings.export_data())
	if not built.ok:
		return {"ok": false, "error": built.error, "warnings": built.warnings}
	if is_available():
		var err := backend.check_config(JsonUtil.stringify(built.config))
		if err != "":
			return {"ok": false, "error": "ядро отклонило конфигурацию: " + err, "warnings": built.warnings}
	return {"ok": true, "error": "", "warnings": built.warnings}


## Generated config for diagnostics, secrets masked.
func preview_config_masked(profile_id: String) -> String:
	var p := Profiles.get_profile(profile_id)
	if p == null:
		return ""
	var built := ConfigBuilder.build_vpn_config(p, Settings.export_data())
	if not built.ok:
		return "ERROR: " + built.error
	return JsonUtil.stringify(SecretMasker.mask_value(built.config), "  ")


## Runs a URL test through the running core; returns delay ms or -1.
func probe_active(timeout_s: float = -1.0) -> int:
	if state != VpnState.State.CONNECTED and state != VpnState.State.CONNECTING:
		return -1
	return await _probe(ConfigBuilder.PROXY_TAG, ConfigBuilder.SERVER_TAG, timeout_s if timeout_s > 0 else float(Settings.get_value("url_test_timeout_s")), _op)


# --- connection flow ---------------------------------------------------------------

func _connect_flow(profile: ProfileModel, is_reconnect: bool) -> Dictionary:
	_op += 1
	var op := _op
	active_profile_id = profile.id
	active_profile_name = profile.name
	exit_ip = ""
	exit_country = ""
	_set_state(VpnState.State.RECONNECTING if is_reconnect else VpnState.State.PREPARING, "")

	var built := ConfigBuilder.build_vpn_config(profile, Settings.export_data())
	if not built.ok:
		return _fail(op, "ошибка конфигурации: " + built.error)
	last_config_warnings = built.warnings
	for w in built.warnings:
		Log.warn("config", w)
	var json := JsonUtil.stringify(built.config)
	var check := backend.check_config(json)
	if check != "":
		return _fail(op, "ядро отклонило конфигурацию: " + check)
	if op != _op:
		return {"ok": false, "error": "отменено"}

	if not backend.has_permission():
		_set_state(VpnState.State.REQUESTING_PERMISSION, "Подтвердите создание VPN-подключения в системном диалоге")
		backend.request_permission()
		var granted := await _wait_permission(op)
		if op != _op:
			return {"ok": false, "error": "отменено"}
		if not granted:
			return _fail(op, "разрешение на VPN не выдано")

	_set_state(VpnState.State.RECONNECTING if is_reconnect else VpnState.State.CONNECTING, "Запуск ядра sing-box")
	var err := backend.start(json, profile.id, profile.name)
	if err != "":
		return _fail(op, err)
	var r := await _wait_core([VpnState.Core.STARTED, VpnState.Core.STOPPED], START_TIMEOUT_S, op)
	if op != _op:
		return {"ok": false, "error": "отменено"}
	if r.timeout:
		backend.stop()
		return _fail(op, "ядро не запустилось за %d с" % int(START_TIMEOUT_S))
	if r.state == VpnState.Core.STOPPED:
		return _fail(op, "ядро остановилось: " + (r.message if r.message != "" else "неизвестная ошибка"))

	if Settings.get_value("verify_connection"):
		_set_state(state, "Проверка соединения через сервер")
		var delay := -1
		for attempt in VERIFY_ATTEMPTS:
			delay = await _probe(ConfigBuilder.PROXY_TAG, ConfigBuilder.SERVER_TAG, float(Settings.get_value("url_test_timeout_s")), op)
			if op != _op:
				return {"ok": false, "error": "отменено"}
			if delay > 0 or _core_state != VpnState.Core.STARTED:
				break
		if delay <= 0:
			backend.stop()
			await _wait_core([VpnState.Core.STOPPED], STOP_TIMEOUT_S, op)
			return _fail(op, "сервер не отвечает: запрос через прокси не прошёл (проверьте параметры сервера)")
		Profiles.set_latency(profile.id, {"ms": delay, "status": ProfileModel.LAT_SLOW if delay > ProfileModel.SLOW_THRESHOLD_MS else ProfileModel.LAT_OK,
			"method": "proxy", "checked_at": int(Time.get_unix_time_from_system()), "error": ""})

	connected_since = int(Time.get_unix_time_from_system())
	_reconnect_attempt = 0
	Settings.set_value("last_connected_profile_id", profile.id)
	History.begin(profile)
	_set_state(VpnState.State.CONNECTED, "" if Settings.get_value("verify_connection") else "соединение не проверялось (проверка отключена)")
	_check_exit_ip(op)
	return {"ok": true, "error": ""}


func _fail(op: int, message: String) -> Dictionary:
	if op == _op:
		last_error = message
		Log.error("vpn", message)
		_finish_session(message)
		_set_state(VpnState.State.ERROR, message)
	return {"ok": false, "error": message}


func _wait_core(targets: Array, timeout_s: float, op: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline:
		if op != _op:
			return {"timeout": false, "state": _core_state, "message": "cancelled"}
		if _core_state in targets:
			return {"timeout": false, "state": _core_state, "message": _core_message}
		await get_tree().create_timer(0.1).timeout
	return {"timeout": true, "state": _core_state, "message": ""}


func _wait_permission(op: int) -> bool:
	var result := [null]
	var cb := func(g: bool) -> void: result[0] = g
	backend.permission_result.connect(cb, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(PERMISSION_TIMEOUT_S * 1000)
	while result[0] == null and Time.get_ticks_msec() < deadline and op == _op:
		await get_tree().create_timer(0.1).timeout
	if backend.permission_result.is_connected(cb):
		backend.permission_result.disconnect(cb)
	return result[0] == true


## Triggers a URL test of [param group] and waits for the item [param tag].
func _probe(group: String, tag: String, timeout_s: float, op: int) -> int:
	var t0 := int(Time.get_unix_time_from_system() * 1000) - 1000
	_url_results.erase(tag)
	var err := backend.url_test(group)
	if err != "":
		Log.warn("vpn", "url test failed to start: " + err)
		return -1
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline and op == _op:
		var item: Dictionary = _url_results.get(tag, {})
		if not item.is_empty() and int(item.get("time", 0)) >= t0 and int(item.get("delay_ms", 0)) > 0:
			return int(item.delay_ms)
		if _core_state != VpnState.Core.STARTED:
			return -1
		await get_tree().create_timer(0.1).timeout
	return -1


func _check_exit_ip(op: int) -> void:
	if not Settings.get_value("ip_check_enabled"):
		return
	var info := await _ip_checker.check(str(Settings.get_value("ip_check_url")))
	if op != _op or state != VpnState.State.CONNECTED:
		return
	if info.ok:
		exit_ip = info.ip
		exit_country = info.country
		if active_profile_id != "":
			Profiles.set_exit_info(active_profile_id, info.country)
	else:
		Log.warn("vpn", "IP check failed: " + info.error)
	ip_info_updated.emit(info)


# --- native events -----------------------------------------------------------------

func _on_core_state(core: int, message: String) -> void:
	_core_state = core
	_core_message = message
	Log.debug("vpn", "core state %d %s" % [core, message])
	if core != VpnState.Core.STOPPED:
		return
	if _user_stop or state in [VpnState.State.STOPPING, VpnState.State.DISCONNECTED, VpnState.State.ERROR]:
		return
	if state in [VpnState.State.PREPARING, VpnState.State.REQUESTING_PERMISSION, VpnState.State.CONNECTING]:
		return # the connect flow handles it
	# Unexpected stop while connected / reconnecting.
	_finish_session(message)
	if message.begins_with("revoked") or message.begins_with("stopped_by_user"):
		# The user stopped it from the notification or another VPN took over:
		# reconnecting would fight the user's decision.
		_reset_runtime()
		_set_state(VpnState.State.DISCONNECTED, "VPN отключён системой или из уведомления" if message.begins_with("revoked") else "")
		return
	_schedule_reconnect("соединение прервано: " + (message if message != "" else "ядро остановлено"))


func _schedule_reconnect(reason: String) -> void:
	_op += 1
	Log.warn("vpn", reason)
	var max_attempts := int(Settings.get_value("reconnect_max_attempts"))
	if not Settings.get_value("auto_reconnect") or _reconnect_attempt >= max_attempts:
		_reset_runtime()
		_set_state(VpnState.State.ERROR, reason)
		return
	if not _network_available:
		_waiting_for_network = true
		_set_state(VpnState.State.RECONNECTING, "ожидание сети")
		return
	_reconnect_attempt += 1
	var delay := minf(float(Settings.get_value("reconnect_base_delay_s")) * pow(2.0, _reconnect_attempt - 1), MAX_RECONNECT_DELAY_S)
	_set_state(VpnState.State.RECONNECTING, "попытка %d из %d через %d с" % [_reconnect_attempt, max_attempts, int(delay)])
	_reconnect_timer.start(delay)


func _on_reconnect_timer() -> void:
	var p := Profiles.get_profile(active_profile_id)
	if p == null:
		_set_state(VpnState.State.ERROR, "профиль для переподключения не найден")
		return
	var r := await _connect_flow(p, true)
	if not r.ok and state == VpnState.State.ERROR and Settings.get_value("auto_reconnect") \
			and _reconnect_attempt < int(Settings.get_value("reconnect_max_attempts")):
		_schedule_reconnect(r.error)


func _on_status(s: Dictionary) -> void:
	_stats.up = int(s.get("up", 0))
	_stats.down = int(s.get("down", 0))
	_stats.up_total = int(s.get("up_total", 0))
	_stats.down_total = int(s.get("down_total", 0))
	_stats.connections = int(s.get("connections", 0))
	_stats.source = "sing-box"
	_stats.updated_at = int(Time.get_unix_time_from_system())
	History.update_traffic(_stats.up_total, _stats.down_total)
	stats_updated.emit(_stats.duplicate())


func _on_logs(entries: Array) -> void:
	for e in entries:
		if typeof(e) == TYPE_ARRAY and e.size() >= 2:
			Log.add_core(int(e[0]), str(e[1]))


func _on_url_test(result: Dictionary) -> void:
	var items: Dictionary = result.get("items", {})
	for tag in items:
		_url_results[tag] = items[tag]


func _on_network_changed(info: Dictionary) -> void:
	var was := _network_available
	_network_available = bool(info.get("available", true))
	Bus.network_changed.emit(info)
	Log.info("network", "network %s (%s)" % ["available" if _network_available else "lost", info.get("type", "?")])
	if not _network_available:
		if state == VpnState.State.CONNECTED:
			_set_state(state, "нет сети — соединение восстановится при её появлении")
		return
	if _waiting_for_network:
		_waiting_for_network = false
		_schedule_reconnect("сеть восстановлена")
		return
	if state == VpnState.State.CONNECTED:
		_set_state(state, "")
		if Settings.get_value("reconnect_on_network_change") and (not was or info.get("changed_type", false)):
			# The core follows default-interface changes itself; resetting drops
			# connections bound to the old network so apps reconnect quickly.
			backend.reset_network()
			Log.info("vpn", "network changed, core connections reset")


# --- helpers -------------------------------------------------------------------------

func _resolve_profile(profile_id: String) -> ProfileModel:
	var pid := profile_id
	if pid == "" and Settings.get_value("connect_best_server"):
		var best := Profiles.best_tested()
		if best:
			pid = best.id
	if pid == "":
		pid = str(Settings.get_value("active_profile_id"))
	var p := Profiles.get_profile(pid)
	if p != null:
		Profiles.set_active(p.id)
	return p


func _set_state(s: int, message: String) -> void:
	var changed := s != state or message != state_message
	state = s
	state_message = message
	if s == VpnState.State.DISCONNECTED:
		connected_since = 0
	if changed:
		if s in [VpnState.State.CONNECTED, VpnState.State.ERROR, VpnState.State.DISCONNECTED]:
			Log.info("vpn", "state: %s%s" % [VpnState.label(s), (" — " + message) if message != "" else ""])
		state_changed.emit(s, message)


func _finish_session(error: String) -> void:
	if History.has_open_session():
		History.finish(error)
	connected_since = 0


func _reset_runtime() -> void:
	connected_since = 0
	_stats = {"up": 0, "down": 0, "up_total": 0, "down_total": 0, "connections": 0, "source": "", "updated_at": 0}
	stats_updated.emit(_stats.duplicate())


## Re-reads the native state (after the app returns to the foreground: events
## may have been missed while the UI was paused).
func sync_with_core() -> void:
	if not is_available():
		return
	var info := backend.get_core_info()
	var core := int(info.get("state", VpnState.Core.STOPPED))
	_core_state = core
	if core == VpnState.Core.STARTED and state in [VpnState.State.DISCONNECTED, VpnState.State.ERROR]:
		_adopt_running_core()
	elif core == VpnState.Core.STOPPED and state == VpnState.State.CONNECTED:
		_on_core_state(core, str(info.get("message", "")))


## If the native service is still running (UI process restarted while the VPN
## kept going), restore the CONNECTED state instead of showing "Disconnected".
func _adopt_running_core() -> void:
	if not is_available():
		return
	var info := backend.get_core_info()
	_core_state = int(info.get("state", VpnState.Core.STOPPED))
	if _core_state == VpnState.Core.STARTED:
		active_profile_id = str(info.get("profile_id", ""))
		active_profile_name = str(info.get("profile_name", ""))
		connected_since = int(int(info.get("started_at", 0)) / 1000)
		var p := Profiles.get_profile(active_profile_id)
		if p and not History.has_open_session():
			History.begin(p)
		_set_state(VpnState.State.CONNECTED, "")
		Log.info("vpn", "attached to running VPN service (%s)" % active_profile_name)
