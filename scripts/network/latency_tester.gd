extends Node
## Autoload "Latency": server checks.
##
## Two clearly separated measurements:
##  * "proxy" - real HTTP request (sing-box default URL-test target,
##    https://www.gstatic.com/generate_204) through
##    the protocol itself, performed by sing-box. Needs the native core
##    (Android). While disconnected a temporary core session without TUN tests
##    many profiles at once; while connected only the active server is tested
##    through the running core.
##  * "tcp"   - TCP handshake time to server:port. Shows the port is reachable,
##    NOT that the proxy works. Used when the core cannot be used (desktop, or
##    other servers while connected). Not applicable to UDP-based protocols.
## Failed checks are stored as "failed" with no delay value (never 0 ms).

signal test_started(ids: Array)
signal test_finished(results: Dictionary)
signal progress(done: int, total: int)

const TCP_TIMEOUT_MS := 5000
const TCP_PARALLEL := 8
const SESSION_TIMEOUT_MS := 15000
const SESSION_BATCH := 64
const UDP_PROTOCOLS := ["hysteria2", "hysteria", "tuic", "wireguard"]

var running := false


## Tests the given profiles. Returns (await) {profile_id: latency record}.
func test_profiles(ids: Array) -> Dictionary:
	if running:
		return {}
	running = true
	test_started.emit(ids)
	var results := {}
	var profiles: Array[ProfileModel] = []
	for id in ids:
		var p := Profiles.get_profile(id)
		if p:
			profiles.append(p)
			Profiles.set_latency(p.id, {"status": ProfileModel.LAT_TESTING, "ms": 0, "method": "", "checked_at": 0, "error": ""})
	var proxy_list: Array[ProfileModel] = []
	var tcp_list: Array[ProfileModel] = []
	var vpn_active := SingBoxManager.is_active() or VpnState.is_busy(SingBoxManager.state)
	for p in profiles:
		if p.protocol == "config":
			results[p.id] = _record(-1, "", "полные конфигурации не тестируются")
		elif SingBoxManager.is_available() and not vpn_active:
			proxy_list.append(p)
		elif vpn_active and p.id == SingBoxManager.active_profile_id and SingBoxManager.state == VpnState.State.CONNECTED:
			var ms: int = await SingBoxManager.probe_active()
			results[p.id] = _record(ms, "proxy", "" if ms > 0 else "запрос через прокси не прошёл")
		else:
			tcp_list.append(p)
	var done := results.size()
	progress.emit(done, profiles.size())
	# Proxy tests in batches through a temporary core session.
	var i := 0
	while i < proxy_list.size():
		var batch := proxy_list.slice(i, i + SESSION_BATCH)
		i += SESSION_BATCH
		var r := await _proxy_session(batch)
		results.merge(r, true)
		done += batch.size()
		progress.emit(done, profiles.size())
	# TCP tests with bounded parallelism.
	var queue := tcp_list.duplicate()
	var active := [0]
	while queue.size() > 0 or active[0] > 0:
		while queue.size() > 0 and active[0] < TCP_PARALLEL:
			var p: ProfileModel = queue.pop_front()
			active[0] += 1
			_tcp_job(p, results, active)
		await get_tree().create_timer(0.05).timeout
		progress.emit(results.size(), profiles.size())
	for id in results:
		Profiles.set_latency(id, results[id])
	running = false
	test_finished.emit(results)
	Log.info("latency", "tested %d servers" % results.size())
	return results


func test_all() -> Dictionary:
	var ids := []
	for p in Profiles.get_all():
		ids.append(p.id)
	return await test_profiles(ids)


func _tcp_job(p: ProfileModel, results: Dictionary, active: Array) -> void:
	if p.protocol in UDP_PROTOCOLS:
		results[p.id] = {"status": ProfileModel.LAT_UNTESTED, "ms": 0, "method": "tcp",
			"checked_at": int(Time.get_unix_time_from_system()),
			"error": "протокол работает по UDP — TCP-проверка неприменима" + ("" if SingBoxManager.is_available() else "; проверка через прокси доступна на Android")}
	else:
		var ms := await tcp_ping(p.server, p.port)
		results[p.id] = _record(ms, "tcp", "" if ms > 0 else "TCP-порт недоступен")
	active[0] -= 1


## TCP connect time in ms, or -1 on failure/timeout. Non-blocking.
func tcp_ping(host: String, port: int) -> int:
	var peer := StreamPeerTCP.new()
	var addr := host
	if not host.is_valid_ip_address():
		var id := IP.resolve_hostname_queue_item(host, IP.TYPE_ANY)
		var t0 := Time.get_ticks_msec()
		while IP.get_resolve_item_status(id) == IP.RESOLVER_STATUS_WAITING:
			if Time.get_ticks_msec() - t0 > TCP_TIMEOUT_MS:
				IP.erase_resolve_item(id)
				return -1
			await get_tree().create_timer(0.02).timeout
		addr = IP.get_resolve_item_address(id)
		IP.erase_resolve_item(id)
		if addr.is_empty():
			return -1
	var start := Time.get_ticks_usec()
	if peer.connect_to_host(addr, port) != OK:
		return -1
	while Time.get_ticks_usec() - start < TCP_TIMEOUT_MS * 1000:
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			var ms := maxi(1, int((Time.get_ticks_usec() - start) / 1000))
			peer.disconnect_from_host()
			return ms
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			return -1
		await get_tree().process_frame
	peer.disconnect_from_host()
	return -1


func _proxy_session(batch: Array) -> Dictionary:
	var out := {}
	var built := ConfigBuilder.build_test_config(batch, Settings.export_data())
	for pid in built.skipped:
		out[pid] = _record(-1, "proxy", built.skipped[pid])
	if not built.ok:
		return out
	var json := JsonUtil.stringify(built.config)
	var backend := SingBoxManager.backend
	var result := [null]
	var cb := func(r: Dictionary) -> void: result[0] = r
	backend.latency_session_finished.connect(cb, CONNECT_ONE_SHOT)
	var err := backend.start_latency_session(json, ConfigBuilder.TEST_GROUP_TAG, SESSION_TIMEOUT_MS)
	if err != "":
		if backend.latency_session_finished.is_connected(cb):
			backend.latency_session_finished.disconnect(cb)
		for tag in built.tags:
			out[built.tags[tag]] = _record(-1, "proxy", err)
		return out
	var deadline := Time.get_ticks_msec() + SESSION_TIMEOUT_MS + 10000
	while result[0] == null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	var r: Dictionary = result[0] if result[0] != null else {"ok": false, "error": "нет ответа от ядра", "items": {}}
	var items: Dictionary = r.get("items", {})
	for tag in built.tags:
		var ms := int(items.get(tag, -1))
		var e := ""
		if ms <= 0:
			e = "запрос через прокси не прошёл" if r.get("ok", false) else str(r.get("error", "ошибка"))
		out[built.tags[tag]] = _record(ms, "proxy", e)
	return out


static func _record(ms: int, method: String, error: String) -> Dictionary:
	var st := ProfileModel.LAT_FAILED
	if ms > 0:
		st = ProfileModel.LAT_SLOW if ms > ProfileModel.SLOW_THRESHOLD_MS else ProfileModel.LAT_OK
	return {"ms": ms if ms > 0 else 0, "status": st, "method": method,
		"checked_at": int(Time.get_unix_time_from_system()), "error": error}
