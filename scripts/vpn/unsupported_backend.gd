class_name UnsupportedVpnBackend
extends VpnBackend
## Backend for platforms without a native VPN implementation yet
## (Windows/Linux/macOS, editor). All operations fail with a clear reason.

var _reason := ""


func _init(reason: String = "") -> void:
	_reason = reason


func unavailable_reason() -> String:
	if _reason != "":
		return _reason
	return "VPN-подключение пока реализовано только для Android (платформа: %s)" % OS.get_name()
