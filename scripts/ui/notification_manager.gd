class_name ToastLayer
extends Control
## In-app notifications (toasts) stacked above the bottom navigation.
## kind: "info" | "success" | "warning" | "error". Errors stay longer.

const MAX_VISIBLE := 3

var _box: VBoxContainer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box = UI.vbox(8)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.anchor_left = 0
	_box.anchor_right = 1
	_box.anchor_top = 1
	_box.anchor_bottom = 1
	_box.offset_left = 16
	_box.offset_right = -16
	_box.offset_bottom = -92
	_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_box.alignment = BoxContainer.ALIGNMENT_END
	add_child(_box)


func show_toast(message: String, kind: String = "info") -> void:
	var color: Color = {"success": Style.c("success"), "warning": Style.c("warning"), "error": Style.c("danger")}.get(kind, Style.c("accent"))
	var p := PanelContainer.new()
	var sb := Style.box(Style.c("surface3"), 14, Color(color, 0.6), 1, 14)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var h := UI.hbox(10)
	var ic := UI.icon({"success": "check", "warning": "warning", "error": "warning"}.get(kind, "info"), 20, color)
	h.add_child(ic)
	var l := UI.label(SecretMasker.mask(message), "", true)
	h.add_child(l)
	p.add_child(h)
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_dismiss(p))
	_box.add_child(p)
	while _box.get_child_count() > MAX_VISIBLE:
		_box.get_child(0).queue_free()
		_box.remove_child(_box.get_child(0))
	p.modulate.a = 0.0
	create_tween().tween_property(p, "modulate:a", 1.0, 0.15)
	var t := 5.0 if kind == "error" else 2.8
	get_tree().create_timer(t).timeout.connect(func() -> void: _dismiss(p))


func _dismiss(p: Control) -> void:
	if not is_instance_valid(p) or p.is_queued_for_deletion():
		return
	var tw := create_tween()
	tw.tween_property(p, "modulate:a", 0.0, 0.2)
	tw.tween_callback(p.queue_free)
