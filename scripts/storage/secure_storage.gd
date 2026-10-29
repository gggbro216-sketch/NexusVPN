class_name SecureStorage
extends RefCounted
## Provides the 256-bit data key used to encrypt files containing secrets
## (profiles, subscriptions).
##
## Android: a random data key is wrapped (AES-GCM) by a non-exportable key in the
## Android Keystore via the native bridge; only the wrapped blob is stored on disk.
## Other platforms: no OS keystore integration yet — the key is stored next to the
## data (protects only against casual inspection). This is reported via
## [method protection_level] and shown in the UI.

const KEY_FILE := "user://keystore.json"

static var _cached_key := PackedByteArray()
static var _level := ""
static var last_error := ""


## Returns a 32-byte key, or an empty array if the key exists but cannot be
## unwrapped (e.g. Keystore was reset). Callers must NOT overwrite data then.
static func get_data_key() -> PackedByteArray:
	if _cached_key.size() == 32:
		return _cached_key
	last_error = ""
	var bridge: Object = Platform.bridge if Platform.has_vpn_backend() else null
	var stored := {}
	if FileAccess.file_exists(KEY_FILE):
		var res := JsonStore.load(KEY_FILE)
		if res.ok and typeof(res.data) == TYPE_DICTIONARY:
			stored = res.data
		else:
			last_error = "key file unreadable: %s" % res.get("error", "")
			return PackedByteArray()
	if stored.is_empty():
		return _create_key(bridge)
	var mode := str(stored.get("mode", ""))
	if mode == "android_keystore":
		if bridge == null:
			last_error = "data was encrypted with the Android Keystore, which is unavailable"
			return PackedByteArray()
		var raw_b64 := str(bridge.keystoreUnwrap(str(stored.get("wrapped", ""))))
		if raw_b64.is_empty():
			last_error = "Android Keystore could not unwrap the data key"
			return PackedByteArray()
		_cached_key = Marshalls.base64_to_raw(raw_b64)
		_level = "android_keystore"
	elif mode == "plain":
		_cached_key = Marshalls.base64_to_raw(str(stored.get("key", "")))
		_level = "plain"
	if _cached_key.size() != 32:
		_cached_key = PackedByteArray()
		last_error = "invalid key material"
	return _cached_key


## "android_keystore" | "plain" | "" (not initialised).
static func protection_level() -> String:
	return _level


static func _create_key(bridge: Object) -> PackedByteArray:
	var crypto := Crypto.new()
	var key := crypto.generate_random_bytes(32)
	var data := {}
	if bridge != null:
		var wrapped := str(bridge.keystoreWrap(Marshalls.raw_to_base64(key)))
		if wrapped.is_empty():
			last_error = "Android Keystore wrap failed"
			return PackedByteArray()
		data = {"mode": "android_keystore", "wrapped": wrapped, "version": 1}
		_level = "android_keystore"
	else:
		data = {"mode": "plain", "key": Marshalls.raw_to_base64(key), "version": 1}
		_level = "plain"
	if JsonStore.save(KEY_FILE, data) != OK:
		last_error = "cannot write key file"
		return PackedByteArray()
	_cached_key = key
	return key


## Forgets the key and deletes the key file (used by "reset encrypted data").
static func reset() -> void:
	_cached_key = PackedByteArray()
	_level = ""
	for p in [KEY_FILE, KEY_FILE + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
