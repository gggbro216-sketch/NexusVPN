extends Node
## Autoload "Settings": persistent application settings (no secrets stored here).
##
## Every key has a default in [constant DEFAULTS]; unknown keys from older/newer
## versions are preserved. Schema migrations run in [method _migrate].

signal changed(key: String, value: Variant)

const PATH := "user://settings.json"
const SCHEMA_VERSION := 1

const ROUTING_MODES := ["global", "split", "selected", "direct", "custom"]
const PER_APP_MODES := ["off", "include", "exclude"]
const TUN_STACKS := ["mixed", "system", "gvisor"]
const DNS_STRATEGIES := ["prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"]
const CORE_LOG_LEVELS := ["trace", "debug", "info", "warn", "error"]

const DEFAULTS := {
	# Connection
	"auto_connect_on_start": false,
	"auto_reconnect": true,
	"reconnect_max_attempts": 5,
	"reconnect_base_delay_s": 2,
	"reconnect_on_network_change": true,
	"verify_connection": true,
	"connect_best_server": false,
	"active_profile_id": "",
	"last_connected_profile_id": "",
	# Network
	"ipv6_enabled": true,
	"tun_stack": "mixed",
	"mtu": 9000,
	"strict_route": true,
	"url_test_timeout_s": 8,
	"ip_check_enabled": true,
	"ip_check_url": "https://www.cloudflare.com/cdn-cgi/trace",
	# DNS
	"remote_dns": "https://1.1.1.1/dns-query",
	"direct_dns": "local",
	"dns_strategy": "prefer_ipv4",
	# Routing
	"routing_mode": "global",
	"bypass_private": true,
	"split_country": "",
	"block_ads": false,
	"custom_rules": [],
	"custom_final": "proxy",
	# Per-app
	"per_app_mode": "off",
	"per_app_packages": [],
	# Subscriptions
	"sub_auto_update": true,
	"sub_update_on_start": true,
	"sub_default_interval_h": 24,
	"sub_user_agent": "NexusVPN/0.1 sing-box/1.14",
	"sub_allow_http": false,
	# Interface
	"theme": "dark",
	"compact_list": false,
	"server_sort": "manual",
	# Notifications
	"notify_on_disconnect": true,
	# Privacy
	"clipboard_detect_on_resume": false,
	# Diagnostics
	"app_log_level": 1,
	"core_log_level": "warn",
}

var _values: Dictionary = {}
var _save_pending := false
var load_error := ""


func _ready() -> void:
	_load()
	changed.connect(func(k: String, v: Variant) -> void:
		if k == "app_log_level":
			Log.min_level = int(v))


func get_value(key: String) -> Variant:
	if _values.has(key):
		return _values[key]
	return DEFAULTS.get(key)


func set_value(key: String, value: Variant) -> void:
	var old: Variant = get_value(key)
	if typeof(old) == typeof(value) and old == value:
		return
	_values[key] = value
	changed.emit(key, value)
	_schedule_save()


func reset_to_defaults() -> void:
	var keep := {"active_profile_id": get_value("active_profile_id")}
	_values = keep
	for k in DEFAULTS:
		changed.emit(k, get_value(k))
	_schedule_save()


func save_now() -> void:
	var data := _values.duplicate(true)
	data["_schema"] = SCHEMA_VERSION
	var err := JsonStore.save(PATH, data)
	if err != OK:
		Log.error("settings", "save failed: %s" % error_string(err))


func export_data() -> Dictionary:
	var d := {}
	for k in DEFAULTS:
		d[k] = get_value(k)
	return d


func import_data(data: Dictionary) -> int:
	var n := 0
	for k in data:
		if not DEFAULTS.has(k):
			continue
		var dt := typeof(DEFAULTS[k])
		var vt := typeof(data[k])
		if dt == vt or (dt in [TYPE_INT, TYPE_FLOAT] and vt in [TYPE_INT, TYPE_FLOAT]):
			set_value(k, data[k])
			n += 1
	return n


func _schedule_save() -> void:
	if _save_pending:
		return
	_save_pending = true
	_deferred_save.call_deferred()


func _deferred_save() -> void:
	_save_pending = false
	save_now()


func _load() -> void:
	var res := JsonStore.load(PATH)
	if not res.ok:
		if FileAccess.file_exists(PATH):
			load_error = res.error
			Log.warn("settings", "settings unreadable, using defaults: %s" % res.error)
		return
	if res.recovered:
		Log.warn("settings", res.error)
	var data: Variant = JsonUtil.normalize_numbers(res.data)
	if typeof(data) != TYPE_DICTIONARY:
		return
	_values = _migrate(data)
	Log.min_level = int(get_value("app_log_level"))


func _migrate(data: Dictionary) -> Dictionary:
	var version := int(data.get("_schema", 0))
	data.erase("_schema")
	if version < 1:
		pass # first schema; nothing to migrate
	# Drop values of the wrong type so a corrupted value cannot crash the UI.
	for k in data.keys():
		if DEFAULTS.has(k):
			var dt := typeof(DEFAULTS[k])
			var vt := typeof(data[k])
			var numeric := dt in [TYPE_INT, TYPE_FLOAT] and vt in [TYPE_INT, TYPE_FLOAT]
			if dt != vt and not numeric:
				data.erase(k)
	return data
