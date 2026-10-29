extends Node
## Autoload "Platform": access to the native Android bridge and app lifecycle.
##
## On Android the "NexusVpnBridge" Godot plugin (addons/android_vpn_bridge) is
## available as an engine singleton. On other platforms [member bridge] is null
## and every VPN feature reports itself as unavailable instead of being faked.

const SINGLETON := "NexusVpnBridge"
const EXPECTED_BRIDGE_API := 1

var bridge: Object = null
var bridge_error := ""


func _ready() -> void:
	if Engine.has_singleton(SINGLETON):
		bridge = Engine.get_singleton(SINGLETON)
		var api := int(bridge.getBridgeApiVersion())
		if api != EXPECTED_BRIDGE_API:
			bridge_error = "bridge API %d, expected %d" % [api, EXPECTED_BRIDGE_API]
			Log.error("platform", bridge_error)
		else:
			Log.info("platform", "native bridge loaded, sing-box %s" % bridge.getCoreVersion())
	elif is_android():
		bridge_error = "Android plugin %s is missing from this build" % SINGLETON
		Log.error("platform", bridge_error)
	else:
		Log.info("platform", "running on %s: no VPN backend (Android only for now)" % OS.get_name())


func is_android() -> bool:
	return OS.get_name() == "Android"


## True when a real VPN backend is available on this platform.
func has_vpn_backend() -> bool:
	return bridge != null and bridge_error == ""


func platform_name() -> String:
	return OS.get_name()


func core_version() -> String:
	if has_vpn_backend():
		return str(bridge.getCoreVersion())
	return ""


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			if what == NOTIFICATION_APPLICATION_RESUMED:
				Bus.app_resumed.emit()
		NOTIFICATION_APPLICATION_PAUSED:
			Bus.app_paused.emit()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			Bus.navigate.emit("back", {})
