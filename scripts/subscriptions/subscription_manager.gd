extends Node
## Autoload "Subscriptions": subscription list management and updates.
##
## Records live in Profiles.subscriptions (encrypted with the profiles, as
## subscription URLs usually embed access tokens). Updates never delete
## existing profiles on network/format errors: the old list is kept and the
## error is stored on the subscription.

signal update_started(id: String)
signal update_finished(id: String, result: Dictionary)

const CHECK_INTERVAL_S := 600.0
const MIN_INTERVAL_H := 1
const MAX_INTERVAL_H := 24 * 14

var _updater: SubscriptionUpdater
var _updating: Dictionary = {}
var _timer: Timer


func _ready() -> void:
	_updater = SubscriptionUpdater.new()
	add_child(_updater)
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL_S
	_timer.autostart = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)


func list() -> Array[Dictionary]:
	return Profiles.subscriptions


func get_sub(id: String) -> Dictionary:
	for s in Profiles.subscriptions:
		if s.id == id:
			return s
	return {}


func is_updating(id: String) -> bool:
	return _updating.has(id)


## Returns {ok, error, id}.
func add(url: String, name: String = "", interval_h: int = -1) -> Dictionary:
	if Profiles.locked:
		return {"ok": false, "error": Profiles.lock_reason, "id": ""}
	var u := url.strip_edges()
	var err := SubscriptionUpdater.validate_url(u, bool(Settings.get_value("sub_allow_http")))
	if err != "":
		return {"ok": false, "error": err, "id": ""}
	for s in Profiles.subscriptions:
		if s.url == u:
			return {"ok": false, "error": "такая подписка уже добавлена", "id": s.id}
	var sub := {
		"id": ProfileModel.new_id(),
		"name": name.strip_edges() if name.strip_edges() != "" else _default_name(u),
		"url": u,
		"enabled": true,
		"auto_update": true,
		"interval_h": interval_h if interval_h > 0 else int(Settings.get_value("sub_default_interval_h")),
		"created_at": int(Time.get_unix_time_from_system()),
		"last_attempt": 0,
		"last_success": 0,
		"last_error": "",
		"count": 0,
		"user_info": {},
	}
	Profiles.subscriptions.append(sub)
	Profiles.notify_subscriptions_changed()
	Log.info("subscriptions", "added subscription %s" % sub.name)
	return {"ok": true, "error": "", "id": sub.id}


func update_fields(id: String, fields: Dictionary) -> String:
	var s := get_sub(id)
	if s.is_empty():
		return "подписка не найдена"
	if fields.has("url"):
		var err := SubscriptionUpdater.validate_url(str(fields.url), bool(Settings.get_value("sub_allow_http")))
		if err != "":
			return err
	if fields.has("interval_h"):
		fields.interval_h = clampi(int(fields.interval_h), MIN_INTERVAL_H, MAX_INTERVAL_H)
	for k in fields:
		if k in ["name", "url", "enabled", "auto_update", "interval_h"]:
			s[k] = fields[k]
	if fields.has("name"):
		s["name_user_set"] = true
	if fields.has("interval_h"):
		s["interval_user_set"] = true
	Profiles.notify_subscriptions_changed()
	return ""


func remove(id: String, remove_profiles: bool = true) -> void:
	for i in Profiles.subscriptions.size():
		if Profiles.subscriptions[i].id == id:
			Profiles.subscriptions.remove_at(i)
			break
	if remove_profiles:
		Profiles.remove_subscription_profiles(id)
	else:
		for p in Profiles.get_all():
			if p.subscription_id == id:
				p.subscription_id = ""
	Profiles.notify_subscriptions_changed()


## Downloads and merges one subscription. Returns (await) a result dictionary:
## {ok, error, added, updated, removed, errors: PackedStringArray, format}.
func refresh(id: String) -> Dictionary:
	var s := get_sub(id)
	if s.is_empty():
		return {"ok": false, "error": "подписка не найдена"}
	if _updating.has(id):
		return {"ok": false, "error": "обновление уже выполняется"}
	_updating[id] = true
	update_started.emit(id)
	s.last_attempt = int(Time.get_unix_time_from_system())
	var res := await _do_refresh(s)
	_updating.erase(id)
	if res.ok:
		s.last_success = s.last_attempt
		s.last_error = ""
		Log.info("subscriptions", "%s: +%d ~%d -%d (%s)" % [s.name, res.added, res.updated, res.removed, res.format])
	else:
		s.last_error = res.error
		Log.warn("subscriptions", "%s: update failed: %s" % [s.name, res.error])
	Profiles.notify_subscriptions_changed()
	update_finished.emit(id, res)
	return res


func _do_refresh(s: Dictionary) -> Dictionary:
	var out := {"ok": false, "error": "", "added": 0, "updated": 0, "removed": 0, "errors": PackedStringArray(), "format": ""}
	var r := await _updater.fetch(s.url, str(Settings.get_value("sub_user_agent")), bool(Settings.get_value("sub_allow_http")))
	if not r.ok:
		out.error = r.error
		return out
	var parsed := SubscriptionParser.parse(r.body)
	out.format = SubscriptionParser.FORMAT_NAMES[parsed.format]
	out.errors = parsed.errors
	if not parsed.ok or parsed.profiles.is_empty():
		out.error = parsed.error if parsed.error != "" else "подписка не содержит серверов"
		return out
	var stats := Profiles.merge_subscription(s.id, parsed.profiles)
	out.added = stats.added
	out.updated = stats.updated
	out.removed = stats.removed
	s.count = parsed.profiles.size()
	var hdr: Dictionary = r.headers
	if hdr.has("subscription-userinfo"):
		s.user_info = SubscriptionUpdater.parse_user_info(hdr["subscription-userinfo"])
	if hdr.has("profile-update-interval") and str(hdr["profile-update-interval"]).is_valid_int() and not s.get("interval_user_set", false):
		s.interval_h = clampi(int(hdr["profile-update-interval"]), MIN_INTERVAL_H, MAX_INTERVAL_H)
	if hdr.has("profile-title") and not s.get("name_user_set", false):
		var t := SubscriptionUpdater.parse_title(hdr["profile-title"])
		if t != "":
			s.name = t
	out.ok = true
	return out


func refresh_all(only_due: bool = false) -> void:
	for s in Profiles.subscriptions.duplicate():
		if not s.get("enabled", true):
			continue
		if only_due and not _is_due(s):
			continue
		await refresh(s.id)


func _is_due(s: Dictionary) -> bool:
	if not s.get("auto_update", true):
		return false
	var interval := clampi(int(s.get("interval_h", 24)), MIN_INTERVAL_H, MAX_INTERVAL_H) * 3600
	var last := maxi(int(s.get("last_success", 0)), int(s.get("last_attempt", 0)) - interval + 900)
	return Time.get_unix_time_from_system() - last >= interval


func _on_timer() -> void:
	if Settings.get_value("sub_auto_update"):
		refresh_all(true)


static func _default_name(url: String) -> String:
	var p := UriUtil.parse(url)
	return str(p.host) if p.ok else "Подписка"
