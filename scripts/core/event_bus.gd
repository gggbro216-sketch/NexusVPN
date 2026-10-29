extends Node
## Autoload "Bus": application-wide signals that decouple UI from services.

## A user-visible message (toast). kind: "info" | "success" | "warning" | "error".
signal toast(message: String, kind: String)
## Request navigation to a named screen ("dashboard", "servers", ...).
signal navigate(screen: String, params: Dictionary)
## Request to open the import sheet (optionally with prefilled text).
signal import_requested(prefill: String)
## Emitted after any import operation finishes.
signal import_finished(result: Dictionary)
## Emitted when a network change was reported by the platform.
signal network_changed(info: Dictionary)
## The app came back to the foreground.
signal app_resumed
## The app went to the background.
signal app_paused


func notify(message: String, kind: String = "info") -> void:
	toast.emit(message, kind)
