extends Control
## Root scene: background, safe-area margins, screen host, bottom navigation,
## overlay layer for sheets and the toast layer.

const NAV_ITEMS := [
	["dashboard", "Главная", "home"],
	["servers", "Серверы", "servers"],
	["subscriptions", "Подписки", "cloud"],
	["statistics", "Статистика", "chart"],
	["settings", "Настройки", "settings"],
]

var _bg: ColorRect
var _safe: MarginContainer
var _host: Control
var _nav_bar: PanelContainer
var _nav_buttons := {}
var _overlay: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg = ColorRect.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_safe = MarginContainer.new()
	_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_safe)
	var col := UI.vbox(0)
	_safe.add_child(col)
	_host = Control.new()
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.clip_contents = true
	col.add_child(_host)
	_nav_bar = _build_nav()
	col.add_child(_nav_bar)
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	var toasts := ToastLayer.new()
	add_child(toasts)

	Nav.attach(_host, _overlay, toasts)
	Nav.tab_changed.connect(_on_tab_changed)
	Style.theme_changed.connect(_apply_colors)
	Bus.import_requested.connect(func(prefill: String) -> void: ImportSheet.open(prefill))
	Profiles.storage_error.connect(_on_storage_error)
	SingBoxManager.state_changed.connect(_on_vpn_state)
	get_viewport().size_changed.connect(_apply_safe_area)
	_apply_colors()
	_apply_safe_area()
	Nav.show_tab("dashboard")
	if Profiles.locked:
		_on_storage_error(Profiles.lock_reason)


func _build_nav() -> PanelContainer:
	var p := PanelContainer.new()
	var row := UI.hbox(0)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for it in NAV_ITEMS:
		var b := Button.new()
		b.theme_type_variation = "FlatButton"
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 60
		var v := UI.vbox(2)
		v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ic := UI.icon(it[2], 24)
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := UI.label(it[1], "CaptionLabel")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_font_size_override("font_size", 11)
		v.add_child(ic)
		v.add_child(l)
		b.add_child(v)
		var tab: String = it[0]
		b.pressed.connect(func() -> void: Nav.show_tab(tab))
		b.set_meta("icon", ic)
		b.set_meta("label", l)
		_nav_buttons[tab] = b
		row.add_child(b)
	p.add_child(row)
	return p


func _apply_colors() -> void:
	_bg.color = Style.c("bg")
	var sb := Style.box(Style.c("surface"), 0, Style.c("border"), 0, 0)
	sb.border_width_top = 1
	sb.border_color = Style.c("border")
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	_nav_bar.add_theme_stylebox_override("panel", sb)
	_on_tab_changed(Nav.current_tab)


func _on_tab_changed(tab: String) -> void:
	for t in _nav_buttons:
		var b: Button = _nav_buttons[t]
		var active: bool = t == tab
		var col: Color = Style.c("accent") if active else Style.c("text3")
		(b.get_meta("icon") as TextureRect).modulate = col
		(b.get_meta("label") as Label).add_theme_color_override("font_color", col)


## Keeps content clear of status bar / notches / gesture bar.
func _apply_safe_area() -> void:
	var win := DisplayServer.window_get_size()
	var safe := DisplayServer.get_display_safe_area()
	var vp := get_viewport_rect().size
	if win.x <= 0 or win.y <= 0 or safe.size.x <= 0:
		return
	var sx := vp.x / float(win.x)
	var sy := vp.y / float(win.y)
	_safe.add_theme_constant_override("margin_top", int(maxi(safe.position.y, 0) * sy))
	_safe.add_theme_constant_override("margin_left", int(maxi(safe.position.x, 0) * sx))
	_safe.add_theme_constant_override("margin_right", int(maxi(win.x - safe.end.x, 0) * sx))
	_safe.add_theme_constant_override("margin_bottom", int(maxi(win.y - safe.end.y, 0) * sy))


func _on_vpn_state(state: int, message: String) -> void:
	if not Settings.get_value("notify_on_disconnect"):
		return
	if state == VpnState.State.ERROR and message != "":
		Nav.toast(message, "error")
	elif state == VpnState.State.RECONNECTING and message.begins_with("попытка 1 "):
		Nav.toast("Соединение прервано, переподключение…", "warning")


func _on_storage_error(message: String) -> void:
	if not Profiles.locked:
		Nav.toast(message, "warning")
		return
	var ok := await Nav.confirm("Данные профилей недоступны",
		"%s\n\nФайл профилей сохранён без изменений. Можно сбросить зашифрованные данные (профили и подписки будут удалены) или закрыть это окно и восстановить резервную копию позже." % message,
		"Сбросить данные", true)
	if ok:
		Profiles.reset_storage()
		Nav.toast("Хранилище профилей создано заново", "warning")
