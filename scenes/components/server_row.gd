class_name ServerRow
extends PanelContainer
## One server in the list: active marker, name (+exit-country flag),
## protocol/address/source, latency with status colour, favourite, menu.

signal selected(id: String)
signal menu_requested(id: String)
signal favorite_toggled(id: String, value: bool)

var profile_id := ""
var _name: Label
var _sub: Label
var _lat: Label
var _star: Button
var _dot: Control
var _compact := false


func setup(p: ProfileModel, active: bool, compact: bool) -> void:
	profile_id = p.id
	_compact = compact
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var h := UI.hbox(10)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(4, 36 if not compact else 22)
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(_dot)
	var texts := UI.vbox(2)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name = UI.label("")
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(_name)
	_sub = UI.label("", "MutedLabel")
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub.visible = not compact
	texts.add_child(_sub)
	h.add_child(texts)
	_lat = UI.label("", "MutedLabel")
	_lat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(_lat)
	_star = UI.icon_button("star_outline", func() -> void: favorite_toggled.emit(profile_id, not Profiles.get_profile(profile_id).favorite), "Избранное", 20)
	h.add_child(_star)
	h.add_child(UI.icon_button("more", func() -> void: menu_requested.emit(profile_id), "Действия", 20))
	add_child(h)
	gui_input.connect(_on_input)
	update_from(p, active)


func update_from(p: ProfileModel, active: bool) -> void:
	var sb := Style.box(Style.c("surface2") if active else Style.c("surface"), 14,
		Style.c("accent") if active else Style.c("border"), 1, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 4
	sb.content_margin_top = 6 if _compact else 10
	sb.content_margin_bottom = 6 if _compact else 10
	add_theme_stylebox_override("panel", sb)
	(_dot as ColorRect).color = Style.c("accent") if active else Color.TRANSPARENT
	var flag := UI.flag(p.exit_country)
	_name.text = ("%s %s" % [flag, p.name]).strip_edges()
	var parts := PackedStringArray([p.protocol_label()])
	if p.protocol != "config":
		parts.append(p.display_address())
	if p.subscription_id != "":
		var s := Subscriptions.get_sub(p.subscription_id)
		if not s.is_empty():
			parts.append(str(s.name))
	elif p.notes != "":
		parts.append(p.notes)
	_sub.text = " · ".join(parts)
	_lat.text = UI.latency_text(p)
	_lat.add_theme_color_override("font_color", UI.latency_color(p))
	var err := str(p.latency.get("error", ""))
	_lat.tooltip_text = err
	_star.icon = Icons.get_icon("star" if p.favorite else "star_outline", 20)
	_star.modulate = Style.c("warning") if p.favorite else Style.c("text3")


func _on_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
		if get_global_rect().has_point(get_global_mouse_position()):
			selected.emit(profile_id)
