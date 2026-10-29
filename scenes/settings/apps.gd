extends Control
## Per-app routing: installed (launchable) apps with icons; the selection is
## used as include_package / exclude_package of the TUN inbound.

var _list: VBoxContainer
var _search: LineEdit
var _info: Label
var _apps: Array = []
var _selected := {}
var _show_system := false


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(Nav.header("Приложения", [UI.icon_button("tune", _toggle_system, "Показать системные")]))
	var top := MarginContainer.new()
	top.add_theme_constant_override("margin_left", 16)
	top.add_theme_constant_override("margin_right", 16)
	var tv := UI.vbox(8)
	top.add_child(tv)
	col.add_child(top)
	_info = UI.label("", "CaptionLabel", true)
	tv.add_child(_info)
	_search = LineEdit.new()
	_search.placeholder_text = "Поиск приложения"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _render())
	tv.add_child(_search)
	var page := UI.page(6)
	_list = UI.body(page)
	col.add_child(UI.scroll(page))
	for p in Settings.get_value("per_app_packages"):
		_selected[str(p)] = true
	_update_info()
	if not Platform.has_vpn_backend():
		_list.add_child(UI.label("Список приложений доступен только на Android.", "MutedLabel", true))
		return
	_list.add_child(UI.label("Загрузка списка приложений…", "MutedLabel"))
	Platform.bridge.connect("apps_loaded", _on_loaded, Object.CONNECT_ONE_SHOT | Object.CONNECT_DEFERRED)
	Platform.bridge.loadInstalledApps()


func _update_info() -> void:
	var mode := str(Settings.get_value("per_app_mode"))
	var m: String = {"off": "Режим: все приложения через VPN — выбор не применяется.", "include": "Режим: только выбранные приложения через VPN.",
		"exclude": "Режим: выбранные приложения в обход VPN."}.get(mode, "")
	_info.text = "%s Выбрано: %d." % [m, _selected.size()]


func _on_loaded(json: String) -> void:
	var j := JsonUtil.parse(json)
	_apps = j.data if j.ok and typeof(j.data) == TYPE_ARRAY else []
	# Keep selected packages that are no longer installed visible so they can be removed.
	var known := {}
	for a in _apps:
		known[a.package] = true
	for p in _selected:
		if not known.has(p):
			_apps.append({"package": p, "label": p + " (не установлено)", "system": false})
	_render()


func _render() -> void:
	for c in _list.get_children():
		c.queue_free()
	var needle := _search.text.strip_edges().to_lower()
	var shown := 0
	for a in _apps:
		if a.get("system", false) and not _show_system and not _selected.has(a.package):
			continue
		if needle != "" and not (str(a.label).to_lower().contains(needle) or str(a.package).contains(needle)):
			continue
		shown += 1
		if shown > 300:
			_list.add_child(UI.label("Уточните поиск, чтобы увидеть остальные приложения", "CaptionLabel"))
			break
		_list.add_child(_row(a))


func _row(a: Dictionary) -> Control:
	var pkg: String = a.package
	var h := UI.hbox(12)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(36, 36)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var png: PackedByteArray = Platform.bridge.getAppIcon(pkg, 72)
	if png.size() > 0:
		var img := Image.new()
		if img.load_png_from_buffer(png) == OK:
			icon.texture = ImageTexture.create_from_image(img)
	h.add_child(icon)
	var texts := UI.vbox(0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := UI.label(str(a.label))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(l)
	var p := UI.label(pkg, "CaptionLabel")
	p.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(p)
	h.add_child(texts)
	var cb := CheckBox.new()
	cb.button_pressed = _selected.has(pkg)
	cb.focus_mode = Control.FOCUS_NONE
	cb.toggled.connect(func(v: bool) -> void:
		if v:
			_selected[pkg] = true
		else:
			_selected.erase(pkg)
		Settings.set_value("per_app_packages", _selected.keys())
		_update_info())
	h.add_child(cb)
	return h


func _toggle_system() -> void:
	_show_system = not _show_system
	Nav.toast("Системные приложения " + ("показаны" if _show_system else "скрыты"))
	_render()
