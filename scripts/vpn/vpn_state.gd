class_name VpnState
extends RefCounted
## Connection states shown in the UI. Every state corresponds to a real stage
## of the native VPN lifecycle; CONNECTED is only entered after the core has
## started AND (if enabled) a request through the proxy has succeeded.

enum State { DISCONNECTED, PREPARING, REQUESTING_PERMISSION, CONNECTING, CONNECTED, RECONNECTING, STOPPING, ERROR }

## Native core states reported by the Android bridge (NexusVpnService.CoreState).
enum Core { STOPPED = 0, STARTING = 1, STARTED = 2, STOPPING = 3 }

const LABELS := {
	State.DISCONNECTED: "Отключено",
	State.PREPARING: "Подготовка",
	State.REQUESTING_PERMISSION: "Запрос разрешения",
	State.CONNECTING: "Подключение",
	State.CONNECTED: "Подключено",
	State.RECONNECTING: "Переподключение",
	State.STOPPING: "Остановка",
	State.ERROR: "Ошибка",
}


static func label(s: int) -> String:
	return LABELS.get(s, "?")


static func is_busy(s: int) -> bool:
	return s in [State.PREPARING, State.REQUESTING_PERMISSION, State.CONNECTING, State.RECONNECTING, State.STOPPING]


static func is_active(s: int) -> bool:
	return s in [State.CONNECTING, State.CONNECTED, State.RECONNECTING]
