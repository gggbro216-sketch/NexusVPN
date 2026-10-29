extends Node
## Autoload "Log": application + core log collector.
##
## Every message is masked with [SecretMasker] on ingestion. Entries are kept in a
## bounded ring buffer (memory-safe) and appended to user://logs/app.log, which is
## rotated when it exceeds [constant MAX_FILE_BYTES].

signal entry_added(entry: Dictionary)
signal cleared

enum Level { DEBUG, INFO, WARNING, ERROR }
const LEVEL_NAMES := ["DEBUG", "INFO", "WARN", "ERROR"]

const MAX_ENTRIES := 2000
const MAX_FILE_BYTES := 1024 * 1024
const LOG_DIR := "user://logs"
const LOG_FILE := "user://logs/app.log"

## Source tags used by the diagnostics filter.
const SOURCE_APP := "app"
const SOURCE_CORE := "core"

var min_level: int = Level.INFO
var _entries: Array[Dictionary] = []
var _file: FileAccess
var _pending_flush := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	_rotate_if_needed()
	_file = FileAccess.open(LOG_FILE, FileAccess.READ_WRITE if FileAccess.file_exists(LOG_FILE) else FileAccess.WRITE)
	if _file:
		_file.seek_end()


func _exit_tree() -> void:
	if _file:
		_file.flush()
		_file = null


func debug(tag: String, message: String) -> void:
	add(Level.DEBUG, tag, message)


func info(tag: String, message: String) -> void:
	add(Level.INFO, tag, message)


func warn(tag: String, message: String) -> void:
	add(Level.WARNING, tag, message)


func error(tag: String, message: String) -> void:
	add(Level.ERROR, tag, message)


## Adds an entry. [param source] is [constant SOURCE_APP] or [constant SOURCE_CORE].
func add(level: int, tag: String, message: String, source: String = SOURCE_APP) -> void:
	if level < min_level:
		return
	var entry := {
		"time": Time.get_unix_time_from_system(),
		"level": clampi(level, Level.DEBUG, Level.ERROR),
		"tag": tag,
		"source": source,
		"message": SecretMasker.mask(message),
	}
	_entries.append(entry)
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - MAX_ENTRIES)
	if OS.is_debug_build() or level >= Level.WARNING:
		print(format_entry(entry))
	if _file:
		_file.store_line(format_entry(entry))
		if not _pending_flush:
			_pending_flush = true
			_flush_later.call_deferred()
	entry_added.emit(entry)


## Maps a sing-box log level (as reported by libbox, logrus-like numbering:
## 0 panic .. 6 trace) to [enum Level] and stores it with the core source tag.
func add_core(core_level: int, message: String) -> void:
	var lvl := Level.INFO
	if core_level <= 2:
		lvl = Level.ERROR
	elif core_level == 3:
		lvl = Level.WARNING
	elif core_level >= 5:
		lvl = Level.DEBUG
	add(lvl, "sing-box", message.strip_edges(), SOURCE_CORE)


func get_entries(level_filter: int = Level.DEBUG, source_filter: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _entries:
		if e.level < level_filter:
			continue
		if source_filter != "" and e.source != source_filter:
			continue
		out.append(e)
	return out


func clear() -> void:
	_entries.clear()
	if _file:
		_file = null
	_file = FileAccess.open(LOG_FILE, FileAccess.WRITE)
	cleared.emit()


func format_entry(e: Dictionary) -> String:
	var t := Time.get_datetime_string_from_unix_time(int(e.time), true)
	return "%s [%s] %s/%s: %s" % [t, LEVEL_NAMES[e.level], e.source, e.tag, e.message]


func export_text(level_filter: int = Level.DEBUG) -> String:
	var lines := PackedStringArray()
	for e in get_entries(level_filter):
		lines.append(format_entry(e))
	# Entries are already masked; mask once more in case a format change slipped one through.
	return SecretMasker.mask("\n".join(lines))


func _flush_later() -> void:
	_pending_flush = false
	if _file:
		_file.flush()
		if _file.get_length() > MAX_FILE_BYTES:
			_file = null
			_rotate_if_needed()
			_file = FileAccess.open(LOG_FILE, FileAccess.WRITE)


func _rotate_if_needed() -> void:
	if not FileAccess.file_exists(LOG_FILE):
		return
	var f := FileAccess.open(LOG_FILE, FileAccess.READ)
	if f == null:
		return
	var size := f.get_length()
	f = null
	if size > MAX_FILE_BYTES:
		DirAccess.rename_absolute(LOG_FILE, LOG_FILE + ".1")
