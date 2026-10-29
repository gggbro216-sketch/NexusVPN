class_name ProfileStorage
extends RefCounted
## Encrypted, versioned persistence for profiles and subscriptions.
##
## File: user://profiles.dat — FileAccess.open_encrypted (AES-256, MD5 checked)
## with the data key from [SecureStorage]. A ".bak" copy of the last good file
## is kept by [JsonStore]. Format: {"_schema": N, "profiles": [...], "subscriptions": [...]}.

const DEFAULT_PATH := "user://profiles.dat"
const SCHEMA_VERSION := 2

var path := DEFAULT_PATH
var key := PackedByteArray()


func _init(p_path: String = DEFAULT_PATH, p_key: PackedByteArray = PackedByteArray()) -> void:
	path = p_path
	key = p_key


func exists() -> bool:
	return JsonStore.exists(path)


## Returns {ok, error, recovered, profiles: Array[ProfileModel], subscriptions: Array[Dictionary]}.
func load_all() -> Dictionary:
	var out := {"ok": false, "error": "", "recovered": false, "profiles": [], "subscriptions": []}
	if not exists():
		out.ok = true
		return out
	var res := JsonStore.load(path, key)
	if not res.ok:
		out.error = res.error
		return out
	out.recovered = res.recovered
	if res.recovered:
		out.error = res.error
	var data: Variant = JsonUtil.normalize_numbers(res.data)
	if typeof(data) != TYPE_DICTIONARY:
		out.error = "profile database has an unexpected structure"
		return out
	data = migrate(data)
	for d in data.get("profiles", []):
		if typeof(d) == TYPE_DICTIONARY and str(d.get("id", "")) != "":
			out.profiles.append(ProfileModel.from_dict(d))
	for s in data.get("subscriptions", []):
		if typeof(s) == TYPE_DICTIONARY and str(s.get("id", "")) != "":
			out.subscriptions.append(s)
	out.ok = true
	return out


func save_all(profiles: Array, subscriptions: Array) -> Error:
	var list := []
	for p in profiles:
		list.append(p.to_dict())
	var data := {"_schema": SCHEMA_VERSION, "profiles": list, "subscriptions": subscriptions}
	return JsonStore.save(path, data, key)


## Upgrades older database layouts in place.
static func migrate(data: Dictionary) -> Dictionary:
	var v := int(data.get("_schema", 1))
	if v < 2:
		# v1 stored latency as a bare int "latency_ms"; v2 uses a structured record.
		for d in data.get("profiles", []):
			if typeof(d) == TYPE_DICTIONARY and d.has("latency_ms"):
				var ms := int(d.latency_ms)
				d.erase("latency_ms")
				d["latency"] = {"ms": ms, "status": ProfileModel.LAT_OK if ms > 0 else ProfileModel.LAT_FAILED,
					"method": "tcp", "checked_at": 0, "error": ""}
	data["_schema"] = SCHEMA_VERSION
	return data
