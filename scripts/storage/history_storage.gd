extends Node
## Autoload "History": connection session history, persisted across restarts.
##
## Session: {start, end, profile_id, profile_name, protocol, up_bytes, down_bytes,
##           result: "ok"|"error"|"interrupted", error, stats_source}
## Profile names are stored, server addresses and credentials are not.

signal changed

const PATH := "user://history.json"
const MAX_SESSIONS := 500
const SCHEMA_VERSION := 1

var sessions: Array[Dictionary] = []
var _current := {}


func _ready() -> void:
	var res := JsonStore.load(PATH)
	if res.ok and typeof(res.data) == TYPE_DICTIONARY:
		for s in JsonUtil.normalize_numbers(res.data).get("sessions", []):
			if typeof(s) == TYPE_DICTIONARY:
				sessions.append(s)
	# A session left open by a crash/kill is closed as interrupted.
	for s in sessions:
		if int(s.get("end", 0)) == 0:
			s.end = int(s.get("last_seen", s.get("start", 0)))
			s.result = "interrupted"


func begin(profile: ProfileModel) -> void:
	_current = {
		"start": int(Time.get_unix_time_from_system()),
		"end": 0,
		"last_seen": int(Time.get_unix_time_from_system()),
		"profile_id": profile.id if profile else "",
		"profile_name": profile.name if profile else "",
		"protocol": profile.protocol_label() if profile else "",
		"up_bytes": 0,
		"down_bytes": 0,
		"result": "ok",
		"error": "",
		"stats_source": "sing-box",
	}
	sessions.append(_current)
	_trim()
	_save()
	changed.emit()


func update_traffic(up_total: int, down_total: int) -> void:
	if _current.is_empty():
		return
	_current.up_bytes = up_total
	_current.down_bytes = down_total
	var now := int(Time.get_unix_time_from_system())
	if now - int(_current.last_seen) >= 30:
		_current.last_seen = now
		_save()


func finish(error: String = "") -> void:
	if _current.is_empty():
		return
	_current.end = int(Time.get_unix_time_from_system())
	if error != "":
		_current.result = "error"
		_current.error = SecretMasker.mask(error)
	_current = {}
	_save()
	changed.emit()


func has_open_session() -> bool:
	return not _current.is_empty()


func last_connected_at() -> int:
	for i in range(sessions.size() - 1, -1, -1):
		if sessions[i].get("result", "") != "error":
			return int(sessions[i].start)
	return 0


func totals() -> Dictionary:
	var up := 0
	var down := 0
	var secs := 0
	for s in sessions:
		up += int(s.get("up_bytes", 0))
		down += int(s.get("down_bytes", 0))
		var e := int(s.get("end", 0))
		if e == 0:
			e = int(Time.get_unix_time_from_system())
		secs += maxi(0, e - int(s.get("start", 0)))
	return {"up": up, "down": down, "seconds": secs, "count": sessions.size()}


func clear() -> void:
	var keep := _current
	sessions.clear()
	if not keep.is_empty():
		sessions.append(keep)
	_save()
	changed.emit()


func _trim() -> void:
	if sessions.size() > MAX_SESSIONS:
		sessions = sessions.slice(sessions.size() - MAX_SESSIONS)


func _save() -> void:
	JsonStore.save(PATH, {"_schema": SCHEMA_VERSION, "sessions": sessions})
