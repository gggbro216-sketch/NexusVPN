extends Node
## Autoload "App": startup sequence and app-wide behaviour that does not belong
## to a single screen (auto-connect, subscription refresh on start, lifecycle).

const APP_STATE_PATH := "user://app_state.json"

var first_run := false
var _state := {}


func _ready() -> void:
	var res := JsonStore.load(APP_STATE_PATH)
	_state = res.data if res.ok and typeof(res.data) == TYPE_DICTIONARY else {}
	first_run = not _state.get("onboarded", false)
	Bus.app_resumed.connect(_on_resumed)
	# Let the UI build first.
	_startup.call_deferred()


func app_name() -> String:
	return str(ProjectSettings.get_setting("application/config/name", "NEXUS VPN"))


func app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


func mark_onboarded() -> void:
	_state["onboarded"] = true
	first_run = false
	JsonStore.save(APP_STATE_PATH, _state)


func _startup() -> void:
	await get_tree().process_frame
	Log.info("app", "%s %s on %s, sing-box %s" % [app_name(), app_version(), OS.get_name(), SingBoxManager.core_version() if SingBoxManager.is_available() else "n/a"])
	if Platform.has_vpn_backend() and not bool(Platform.bridge.hasNotificationPermission()):
		# Android 13+: the VPN status notification needs this permission.
		Platform.bridge.requestNotificationPermission()
	if Settings.get_value("sub_update_on_start") and Settings.get_value("sub_auto_update") and not Profiles.locked:
		Subscriptions.refresh_all(true)
	if Settings.get_value("auto_connect_on_start") and SingBoxManager.state == VpnState.State.DISCONNECTED and not Profiles.locked:
		var pid := ""
		if str(Settings.get_value("last_connected_profile_id")) != "" and Profiles.has_profile(str(Settings.get_value("last_connected_profile_id"))):
			pid = str(Settings.get_value("last_connected_profile_id"))
		if SingBoxManager.is_available() and (pid != "" or Profiles.get_active() != null):
			Log.info("app", "auto-connect on start")
			SingBoxManager.start_vpn(pid)


func _on_resumed() -> void:
	SingBoxManager.sync_with_core()
	if Settings.get_value("clipboard_detect_on_resume"):
		var clip := DisplayServer.clipboard_get().strip_edges()
		# The clipboard is only inspected locally; nothing is sent anywhere.
		if clip != "" and clip.length() < 64 * 1024 and (LinkParser.is_share_link(clip.split("\n")[0]) or clip.begins_with("https://")):
			if clip.sha256_text() != str(_state.get("last_clipboard_hash", "")):
				_state["last_clipboard_hash"] = clip.sha256_text()
				JsonStore.save(APP_STATE_PATH, _state)
				Bus.import_requested.emit(clip)
