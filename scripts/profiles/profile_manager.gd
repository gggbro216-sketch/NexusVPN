extends Node
## Autoload "Profiles": the profile and subscription database.
##
## All data containing secrets (profiles, subscription URLs) is kept in one
## encrypted file managed by [ProfileStorage]. If the encryption key cannot be
## obtained, the manager enters the "locked" state and never overwrites the
## existing file.

signal profiles_changed
signal profile_updated(id: String)
signal active_changed(id: String)
signal subscriptions_changed
signal storage_error(message: String)

var _profiles: Array[ProfileModel] = []
var _by_id: Dictionary = {}
## Raw subscription records, owned by the Subscriptions autoload.
var subscriptions: Array[Dictionary] = []
var _storage: ProfileStorage
var locked := false
var lock_reason := ""
var _save_pending := false
var storage_path := ProfileStorage.DEFAULT_PATH


func _ready() -> void:
	load_from_disk()


## (Re)loads the database. Tests may set [member storage_path] first.
func load_from_disk() -> void:
	_profiles.clear()
	_by_id.clear()
	subscriptions.clear()
	locked = false
	lock_reason = ""
	var key := SecureStorage.get_data_key()
	if key.size() != 32:
		_lock("ключ шифрования недоступен: " + SecureStorage.last_error)
		return
	_storage = ProfileStorage.new(storage_path, key)
	var res := _storage.load_all()
	if not res.ok:
		_lock("база профилей не читается: " + res.error)
		return
	if res.recovered:
		Log.warn("profiles", res.error)
		storage_error.emit("База профилей восстановлена из резервной копии")
	for p in res.profiles:
		_add_internal(p)
	for s in res.subscriptions:
		subscriptions.append(s)
	_sort_by_order()
	Log.info("profiles", "loaded %d profiles, %d subscriptions (key: %s)" % [_profiles.size(), subscriptions.size(), SecureStorage.protection_level()])
	profiles_changed.emit()
	subscriptions_changed.emit()


func _lock(reason: String) -> void:
	locked = true
	lock_reason = reason
	Log.error("profiles", reason)
	storage_error.emit(reason)


## Deletes the encrypted database and key (user-confirmed recovery path).
func reset_storage() -> void:
	for p in [storage_path, storage_path + ".bak", storage_path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	SecureStorage.reset()
	load_from_disk()


# --- queries -----------------------------------------------------------------

func count() -> int:
	return _profiles.size()


func get_all() -> Array[ProfileModel]:
	return _profiles.duplicate()


func get_profile(id: String) -> ProfileModel:
	return _by_id.get(id)


func has_profile(id: String) -> bool:
	return _by_id.has(id)


func get_active() -> ProfileModel:
	var id := str(Settings.get_value("active_profile_id"))
	return _by_id.get(id)


func set_active(id: String) -> void:
	if not _by_id.has(id):
		return
	Settings.set_value("active_profile_id", id)
	active_changed.emit(id)


## filter: "all" | "favorites" | "manual" | "sub:<id>"; sort: "manual" | "latency" | "name"
func query(text: String = "", filter: String = "all", sort: String = "manual") -> Array[ProfileModel]:
	var out: Array[ProfileModel] = []
	var needle := text.strip_edges().to_lower()
	for p in _profiles:
		if filter == "favorites" and not p.favorite:
			continue
		if filter == "manual" and p.subscription_id != "":
			continue
		if filter.begins_with("sub:") and p.subscription_id != filter.substr(4):
			continue
		if needle != "":
			var hay := ("%s %s %s %s" % [p.name, p.server, p.protocol_label(), p.exit_country]).to_lower()
			if not hay.contains(needle):
				continue
		out.append(p)
	match sort:
		"latency":
			out.sort_custom(func(a: ProfileModel, b: ProfileModel) -> bool:
				return _latency_key(a) < _latency_key(b))
		"name":
			out.sort_custom(func(a: ProfileModel, b: ProfileModel) -> bool:
				return a.name.naturalnocasecmp_to(b.name) < 0)
	return out


static func _latency_key(p: ProfileModel) -> int:
	var st := p.latency_status()
	if st in [ProfileModel.LAT_OK, ProfileModel.LAT_SLOW]:
		return int(p.latency.get("ms", 999999))
	if st == ProfileModel.LAT_FAILED:
		return 10000000
	return 5000000


## Best profile among those whose last test succeeded (proxy tests preferred).
func best_tested(candidates: Array[ProfileModel] = []) -> ProfileModel:
	var list := candidates if candidates.size() > 0 else _profiles
	var best: ProfileModel = null
	var best_ms := 1 << 30
	for method in ["proxy", "tcp"]:
		for p in list:
			if p.latency_status() in [ProfileModel.LAT_OK, ProfileModel.LAT_SLOW] and p.latency.get("method", "") == method:
				var ms := int(p.latency.get("ms", 0))
				if ms > 0 and ms < best_ms:
					best_ms = ms
					best = p
		if best != null:
			return best
	return best


# --- mutations ---------------------------------------------------------------

## Adds a profile. Returns {added: bool, duplicate_of: String}.
func add_profile(p: ProfileModel, dedupe: bool = true) -> Dictionary:
	if locked:
		return {"added": false, "duplicate_of": "", "error": lock_reason}
	if dedupe:
		var dup := find_duplicate(p)
		if dup != null:
			return {"added": false, "duplicate_of": dup.id, "error": ""}
	p.order = _next_order()
	_add_internal(p)
	_changed()
	return {"added": true, "duplicate_of": "", "error": ""}


func find_duplicate(p: ProfileModel) -> ProfileModel:
	var fp := p.fingerprint()
	for q in _profiles:
		if q.fingerprint() == fp:
			return q
	return null


## Imports any supported text (links, base64 list, sing-box JSON, WireGuard conf).
## Returns {ok, error, added: Array[String], duplicates: int, warnings, errors, format,
##          is_full_config, config}.
func import_text(text: String, source: String) -> Dictionary:
	var out := {"ok": false, "error": "", "added": [], "duplicates": 0, "warnings": PackedStringArray(),
		"errors": PackedStringArray(), "format": "", "is_full_config": false, "config": {}}
	if locked:
		out.error = lock_reason
		return out
	var parsed := SubscriptionParser.parse(text)
	out.format = SubscriptionParser.FORMAT_NAMES[parsed.format]
	out.warnings = parsed.warnings
	out.errors = parsed.errors
	out.is_full_config = parsed.is_full_config
	out.config = parsed.config
	if not parsed.ok:
		out.error = parsed.error
		Log.warn("import", "import failed (%s): %s" % [out.format, parsed.error])
		return out
	for p in parsed.profiles:
		var prof: ProfileModel = p
		prof.source = source
		var r := add_profile(prof)
		if r.added:
			out.added.append(prof.id)
		else:
			out.duplicates += 1
	out.duplicates += int(parsed.duplicates)
	out.ok = true
	Log.info("import", "imported %d profiles (%s), %d duplicates, %d errors" % [out.added.size(), out.format, out.duplicates, out.errors.size()])
	return out


## Stores a full sing-box configuration as a single runnable profile.
func add_full_config(config: Dictionary, name: String) -> ProfileModel:
	var p := ProfileModel.new()
	p.id = ProfileModel.new_id()
	p.protocol = "config"
	p.outbound = config.duplicate(true)
	p.name = name if name != "" else "sing-box config"
	p.server = "—"
	p.source = ProfileModel.SOURCE_SINGBOX_JSON
	p.transport_label = "%d outbounds" % (config.get("outbounds", []) as Array).size()
	p.created_at = int(Time.get_unix_time_from_system())
	p.updated_at = p.created_at
	add_profile(p, false)
	return p


func update_profile(p: ProfileModel) -> String:
	var err := ProfileValidator.validate(p)
	if err != "":
		return err
	p.updated_at = int(Time.get_unix_time_from_system())
	if p.protocol != "config":
		p.server = str(p.outbound.get("server", p.server))
		p.port = int(p.outbound.get("server_port", p.port))
	_by_id[p.id] = p
	for i in _profiles.size():
		if _profiles[i].id == p.id:
			_profiles[i] = p
	profile_updated.emit(p.id)
	_changed()
	return ""


func rename(id: String, new_name: String) -> String:
	var p: ProfileModel = _by_id.get(id)
	if p == null:
		return "профиль не найден"
	var n := new_name.strip_edges()
	if n.is_empty():
		return "название не может быть пустым"
	p.name = n
	p.user_renamed = true
	p.updated_at = int(Time.get_unix_time_from_system())
	profile_updated.emit(id)
	_changed()
	return ""


func duplicate_profile(id: String) -> ProfileModel:
	var p: ProfileModel = _by_id.get(id)
	if p == null:
		return null
	var c := p.duplicate_profile()
	add_profile(c, false)
	return c


func remove(id: String) -> void:
	remove_many([id])


func remove_many(ids: Array) -> void:
	var changed := false
	for id in ids:
		var p: ProfileModel = _by_id.get(id)
		if p == null:
			continue
		_by_id.erase(id)
		_profiles.erase(p)
		changed = true
	if changed:
		if not _by_id.has(str(Settings.get_value("active_profile_id"))):
			Settings.set_value("active_profile_id", "")
			active_changed.emit("")
		_changed()


func set_favorite(id: String, fav: bool) -> void:
	var p: ProfileModel = _by_id.get(id)
	if p and p.favorite != fav:
		p.favorite = fav
		profile_updated.emit(id)
		_changed()


## Moves a profile up (-1) or down (+1) in the manual order.
func move(id: String, delta: int) -> void:
	var p: ProfileModel = _by_id.get(id)
	if p == null:
		return
	var i := _profiles.find(p)
	var j := clampi(i + delta, 0, _profiles.size() - 1)
	if i == j:
		return
	_profiles.remove_at(i)
	_profiles.insert(j, p)
	for k in _profiles.size():
		_profiles[k].order = k
	_changed()


func set_latency(id: String, record: Dictionary) -> void:
	var p: ProfileModel = _by_id.get(id)
	if p == null:
		return
	p.latency = record
	profile_updated.emit(id)
	_schedule_save()


func set_exit_info(id: String, country: String) -> void:
	var p: ProfileModel = _by_id.get(id)
	if p == null:
		return
	p.exit_country = country
	p.exit_ip_checked_at = int(Time.get_unix_time_from_system())
	profile_updated.emit(id)
	_schedule_save()


## Replaces the profiles of a subscription with freshly parsed ones while
## keeping ids, user names, favourites, order and latency of matched entries.
## Only call after a successful download+parse. Returns {added, updated, removed, kept_active}.
func merge_subscription(sub_id: String, fresh: Array) -> Dictionary:
	var stats := {"added": 0, "updated": 0, "removed": 0, "kept_active": false}
	if locked:
		return stats
	var old: Array[ProfileModel] = []
	for p in _profiles:
		if p.subscription_id == sub_id:
			old.append(p)
	var by_fp := {}
	var by_ep := {}
	var by_name := {}
	for p in old:
		by_fp[p.fingerprint()] = p
		by_ep[p.endpoint_key()] = by_ep.get(p.endpoint_key(), []) + [p]
		by_name[p.name] = p
	var matched := {}
	var insert_at := _profiles.size()
	if old.size() > 0:
		insert_at = _profiles.find(old[0])
	var result: Array[ProfileModel] = []
	for f in fresh:
		var np: ProfileModel = f
		np.subscription_id = sub_id
		np.source = ProfileModel.SOURCE_SUBSCRIPTION
		var prev: ProfileModel = by_fp.get(np.fingerprint())
		if prev == null or matched.has(prev.id):
			prev = null
			for cand in by_ep.get(np.endpoint_key(), []):
				if not matched.has(cand.id):
					prev = cand
					break
		if prev == null and by_name.has(np.name) and not matched.has(by_name[np.name].id):
			prev = by_name[np.name]
		if prev != null:
			matched[prev.id] = true
			np.id = prev.id
			np.favorite = prev.favorite
			np.created_at = prev.created_at
			np.exit_country = prev.exit_country
			if prev.fingerprint() == np.fingerprint():
				np.latency = prev.latency
			if prev.user_renamed:
				np.name = prev.name
				np.user_renamed = true
			stats.updated += 1
		else:
			stats.added += 1
		result.append(np)
	var active_id := str(Settings.get_value("active_profile_id"))
	var connected_id := SingBoxManager.active_profile_id if SingBoxManager.is_active() else ""
	# Remove old entries, except the active/connected one which is detached instead.
	for p in old:
		_profiles.erase(p)
		_by_id.erase(p.id)
		if not matched.has(p.id):
			if p.id == active_id or p.id == connected_id:
				p.subscription_id = ""
				p.notes = "удалён из подписки"
				stats.kept_active = true
				_profiles.insert(mini(insert_at, _profiles.size()), p)
				_by_id[p.id] = p
			else:
				stats.removed += 1
	var pos := clampi(insert_at, 0, _profiles.size())
	for np in result:
		_profiles.insert(pos, np)
		_by_id[np.id] = np
		pos += 1
	for k in _profiles.size():
		_profiles[k].order = k
	_changed()
	return stats


func remove_subscription_profiles(sub_id: String) -> int:
	var ids := []
	for p in _profiles:
		if p.subscription_id == sub_id:
			ids.append(p.id)
	remove_many(ids)
	return ids.size()


func notify_subscriptions_changed() -> void:
	subscriptions_changed.emit()
	_schedule_save()


# --- export / backup -------------------------------------------------------------

## Share links of the given profiles (secrets included — caller must warn the user).
func export_links(ids: Array) -> String:
	var lines := PackedStringArray()
	for id in ids:
		var p: ProfileModel = _by_id.get(id)
		if p and p.uri != "":
			lines.append(p.uri)
	return "\n".join(lines)


## Full backup (profiles, subscriptions, settings). Contains secrets.
func export_backup() -> String:
	var list := []
	for p in _profiles:
		list.append(p.to_dict())
	var data := {"app": ProjectSettings.get_setting("application/config/name"), "backup_version": 1,
		"created_at": int(Time.get_unix_time_from_system()), "profiles": list,
		"subscriptions": subscriptions, "settings": Settings.export_data()}
	return JsonUtil.stringify(data, "  ")


## Restores a backup made by [method export_backup]; existing profiles are kept,
## duplicates skipped. Returns {ok, error, profiles, subscriptions, settings}.
func import_backup(text: String, restore_settings: bool) -> Dictionary:
	var out := {"ok": false, "error": "", "profiles": 0, "subscriptions": 0, "settings": 0}
	var j := JsonUtil.parse(text)
	if not j.ok or typeof(j.data) != TYPE_DICTIONARY or not j.data.has("backup_version"):
		out.error = "файл не является резервной копией приложения"
		return out
	for d in j.data.get("profiles", []):
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var p := ProfileModel.from_dict(d)
		if ProfileValidator.validate(p) != "" or _by_id.has(p.id):
			continue
		if add_profile(p).added:
			out.profiles += 1
	for s in j.data.get("subscriptions", []):
		if typeof(s) == TYPE_DICTIONARY and str(s.get("id", "")) != "":
			var exists := false
			for e in subscriptions:
				if e.id == s.id or e.get("url", "") == s.get("url", ""):
					exists = true
			if not exists:
				subscriptions.append(s)
				out.subscriptions += 1
	if restore_settings and typeof(j.data.get("settings")) == TYPE_DICTIONARY:
		out.settings = Settings.import_data(j.data.settings)
	notify_subscriptions_changed()
	_changed()
	out.ok = true
	return out


# --- internals -----------------------------------------------------------------

func _add_internal(p: ProfileModel) -> void:
	_profiles.append(p)
	_by_id[p.id] = p


func _next_order() -> int:
	var m := -1
	for p in _profiles:
		m = maxi(m, p.order)
	return m + 1


func _sort_by_order() -> void:
	_profiles.sort_custom(func(a: ProfileModel, b: ProfileModel) -> bool: return a.order < b.order)


func _changed() -> void:
	profiles_changed.emit()
	_schedule_save()


func _schedule_save() -> void:
	if _save_pending or locked:
		return
	_save_pending = true
	_save_deferred.call_deferred()


func _save_deferred() -> void:
	_save_pending = false
	save_now()


func save_now() -> Error:
	if locked or _storage == null:
		return ERR_LOCKED
	var err := _storage.save_all(_profiles, subscriptions)
	if err != OK:
		var msg := "не удалось сохранить профили: %s" % error_string(err)
		Log.error("profiles", msg)
		storage_error.emit(msg)
	return err
