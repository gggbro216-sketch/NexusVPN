class_name ConnectButton
extends Control
## Large circular connect/disconnect button. Redraws continuously only while a
## transition is in progress (spinner arc); idle states are static.

signal clicked

var state: int = VpnState.State.DISCONNECTED:
	set(v):
		state = v
		set_process(VpnState.is_busy(v))
		queue_redraw()

var _phase := 0.0
var _press := 0.0
var _icon: Texture2D


func _ready() -> void:
	custom_minimum_size = Vector2(210, 210)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_icon = Icons.get_icon("power", 64)
	set_process(false)
	Style.theme_changed.connect(queue_redraw)


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * 1.4, 1.0)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var inside: bool = (event.position - size / 2.0).length() <= minf(size.x, size.y) / 2.0
		if event.pressed and inside:
			_animate_press(1.0)
		elif not event.pressed:
			_animate_press(0.0)
			if inside:
				clicked.emit()
		accept_event()


func _animate_press(to: float) -> void:
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void:
		_press = v
		queue_redraw(), _press, to, 0.12)


func _color() -> Color:
	match state:
		VpnState.State.CONNECTED:
			return Style.c("success")
		VpnState.State.ERROR:
			return Style.c("danger")
		VpnState.State.DISCONNECTED:
			return Style.c("text3")
	return Style.c("accent")


func _draw() -> void:
	var center := size / 2.0
	var r := minf(size.x, size.y) / 2.0 - 6.0
	var col := _color()
	var active := state == VpnState.State.CONNECTED
	# Outer halo
	for i in 3:
		var a := (0.10 if active else 0.05) * (1.0 - i / 3.0)
		draw_circle(center, r - i * 6.0, Color(col, a))
	# Ring
	var inner := r * (0.80 - _press * 0.03)
	draw_circle(center, inner, Style.c("surface"))
	draw_arc(center, inner, 0, TAU, 96, Color(col, 0.35), 3.0, true)
	if VpnState.is_busy(state):
		var start := _phase * TAU
		draw_arc(center, inner, start, start + PI * 0.6, 48, col, 5.0, true)
	elif active:
		draw_arc(center, inner, 0, TAU, 96, col, 5.0, true)
	# Icon
	if _icon:
		var s := inner * 0.62
		draw_texture_rect(_icon, Rect2(center - Vector2(s, s) / 2.0, Vector2(s, s)), false, col)
