class_name JsonStore
extends RefCounted
## Crash-safe JSON persistence.
##
## save(): writes "<path>.tmp", verifies it can be read back, keeps the previous
## good file as "<path>.bak", then renames the temp file into place.
## load(): falls back to the backup when the main file is missing or corrupted.
## When a 32-byte key is supplied the file is written with
## FileAccess.open_encrypted (AES-256 + MD5 integrity check).

const MAX_FILE_BYTES := 32 * 1024 * 1024


static func save(path: String, data: Variant, key: PackedByteArray = PackedByteArray()) -> Error:
	var text := JSON.stringify(data, "", false)
	var tmp := path + ".tmp"
	var err := _write(tmp, text, key)
	if err != OK:
		return err
	# Verify the temp file before replacing the good one.
	var check := _read(tmp, key)
	if not check.ok:
		DirAccess.remove_absolute(tmp)
		return ERR_FILE_CORRUPT
	if FileAccess.file_exists(path):
		var bak := path + ".bak"
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(path, bak)
	err = DirAccess.rename_absolute(tmp, path)
	return err


## Returns {ok: bool, data: Variant, recovered: bool, error: String}.
static func load(path: String, key: PackedByteArray = PackedByteArray()) -> Dictionary:
	var res := _read(path, key)
	if res.ok:
		return res
	var bak := path + ".bak"
	if FileAccess.file_exists(bak):
		var b := _read(bak, key)
		if b.ok:
			b.recovered = true
			b.error = "main file unreadable (%s), restored from backup" % res.error
			return b
	return res


static func exists(path: String) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


static func _write(path: String, text: String, key: PackedByteArray) -> Error:
	var f: FileAccess
	if key.size() == 32:
		f = FileAccess.open_encrypted(path, FileAccess.WRITE, key)
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	var err := f.get_error()
	f.close()
	return err


static func _read(path: String, key: PackedByteArray) -> Dictionary:
	var res := {"ok": false, "data": null, "recovered": false, "error": ""}
	if not FileAccess.file_exists(path):
		res.error = "not found"
		return res
	var f: FileAccess
	if key.size() == 32:
		f = FileAccess.open_encrypted(path, FileAccess.READ, key)
	else:
		f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		res.error = "open failed: %s" % error_string(FileAccess.get_open_error())
		return res
	if f.get_length() > MAX_FILE_BYTES:
		res.error = "file too large"
		return res
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		res.error = "invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()]
		return res
	res.ok = true
	res.data = json.data
	return res
