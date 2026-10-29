extends Node
## Autoload "Nav": screen navigation (bottom tabs + pushed pages), bottom
## sheets, dialogs and toasts. The main scene attaches its containers via
## [method attach]; screens are loaded lazily and cached (tabs) or created on
## push (pages).

signal tab_changed(name: String)

const SCREENS := {
	"dashboard": "res://scenes/dashboard/dashboard.tscn",
	"servers": "res://scenes/servers/servers.tscn",
	"subscriptions": "res://scenes/subscriptions/subscriptions.tscn",
	"statistics": "res://scenes/statistics/statistics.tscn",
	"settings": "res://scenes/settings/settings.tscn",
	"diagnostics": "res://scenes/diagnostics/diagnostics.tscn",
	"profile_editor": "res://scenes/servers/profile_editor.tscn",
	"settings_page": "res://scenes/settings/settings_page.tscn",
	"apps": "res://scenes/settings/apps.tscn",
	"rules": "res://scenes/settings/rules.tscn",
}
const TABS := ["dashboard", "servers", "subscriptions", "statistics", "settings"]
const ANIM_TIME := 0.18

var current_tab := ""
var _host: Control
var _overlay: Control
var _toasts: ToastLayer
var _tabs := {}
var _stack: Array[Control] = []
var _sheet: Control = null


func attach(host: Control, overlay: Control, toasts: ToastLayer) -> void:
	_host = host
	_overlay = overlay
	_toasts = toasts
	Bus.toast.connect(toast)
	Bus.navigate.connect(func(screen: String, params: Dictionary) -> void:
		if screen == "back":
			back()
		elif screen in TABS:
			show_tab(screen)
		else:
			push(screen, params))
	get_tree().quit_on_go_back = false


func show_tab(name: String) -> void:
	while _stack.size() > 0:
		_pop_now()
	if name == current_tab:
		var cur: Control = _tabs.get(name)
		if cur and cur.has_method("on_reselected"):
			cur.on_reselected()
		return
	var prev: Control = _tabs.get(current_tab)
	var next: Control = _tabs.get(name)
	if next == null:
		next = _instantiate(name)
		if next == null:
			return
		_tabs[name] = next
		_host.add_child(next)
	if prev:
		prev.visible = false
		if prev.has_method("on_hidden"):
			prev.on_hidden()
	current_tab = name
	next.visible = true
	next.modulate.a = 0.0
	create_tween().tween_property(next, "modulate:a", 1.0, ANIM_TIME)
	if next.has_method("on_shown"):
		next.on_shown()
	tab_changed.emit(name)


func push(name: String, params: Dictionary = {}) -> Control:
	var page := _instantiate(name)
	if page == null:
		return null
	if page.has_method("setup"):
		page.setup(params)
	var bg := Style.box(Style.c("bg"), 0)
	var holder := PanelContainer.new()
	holder.add_theme_stylebox_override("panel", bg)
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(page)
	_host.add_child(holder)
	_stack.append(holder)
	holder.position.x = _host.size.x * 0.25
	holder.modulate.a = 0.0
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(holder, "position:x", 0.0, ANIM_TIME)
	tw.tween_property(holder, "modulate:a", 1.0, ANIM_TIME)
	if page.has_method("on_shown"):
		page.on_shown()
	return page


func pop() -> void:
	if _stack.is_empty():
		return
	var holder: Control = _stack.pop_back()
	var tw := create_tween().set_parallel()
	tw.tween_property(holder, "position:x", _host.size.x * 0.25, ANIM_TIME)
	tw.tween_property(holder, "modulate:a", 0.0, ANIM_TIME)
	tw.chain().tween_callback(holder.queue_free)
	_refresh_visible()


func _pop_now() -> void:
	var holder: Control = _stack.pop_back()
	holder.queue_free()


func _refresh_visible() -> void:
	var top: Control = _stack.back() if _stack.size() > 0 else _tabs.get(current_tab)
	if top == null:
		return
	var page: Node = top.get_child(0) if top in _stack else top
	if page and page.has_method("on_shown"):
		page.on_shown()


## Android back button / gesture.
func back() -> void:
	if _sheet != null:
		close_sheet()
		return
	if _stack.size() > 0:
		pop()
		return
	if current_tab != "dashboard":
		show_tab("dashboard")
		return
	# Leaving the app must not quit the process (see NexusVpnPlugin.moveToBack).
	if Platform.has_vpn_backend():
		Platform.bridge.moveToBack()


func _instantiate(name: String) -> Control:
	if not SCREENS.has(name):
		push_error("unknown screen " + name)
		return null
	var scene: PackedScene = load(SCREENS[name])
	var node: Control = scene.instantiate()
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return node


# --- sheets & dialogs ---------------------------------------------------------------

## Shows [param content] in a bottom sheet. Returns the sheet root.
func sheet(content: Control, title: String = "") -> Control:
	close_sheet()
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Style.c("overlay")
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			close_sheet())
	root.add_child(dim)
	var panel := PanelContainer.new()
	var sb := Style.box(Style.c("surface"), 0, Style.c("border"), 0, 0)
	sb.corner_radius_top_left = 22
	sb.corner_radius_top_right = 22
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 26
	panel.add_theme_stylebox_override("panel", sb)
	panel.anchor_left = 0
	panel.anchor_right = 1
	panel.anchor_top = 1
	panel.anchor_bottom = 1
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var col := UI.vbox(12)
	var grip := ColorRect.new()
	grip.color = Style.c("border")
	grip.custom_minimum_size = Vector2(40, 4)
	grip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(grip)
	if title != "":
		col.add_child(UI.label(title, "HeaderLabel"))
	var max_h := _overlay.size.y * 0.82
	var sc := UI.scroll(content)
	sc.custom_minimum_size.y = 0
	col.add_child(sc)
	panel.add_child(col)
	root.add_child(panel)
	_overlay.add_child(root)
	_sheet = root
	# Size the scroll area to the content, capped at 82% of the screen.
	await get_tree().process_frame
	if not is_instance_valid(sc):
		return root
	sc.custom_minimum_size.y = minf(content.get_combined_minimum_size().y, max_h - 80)
	dim.modulate.a = 0
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(dim, "modulate:a", 1.0, ANIM_TIME)
	tw.tween_property(panel, "offset_top", -panel.get_combined_minimum_size().y, ANIM_TIME * 1.3).from(0.0)
	return root


func close_sheet() -> void:
	if _sheet == null:
		return
	var s := _sheet
	_sheet = null
	var tw := create_tween()
	tw.tween_property(s, "modulate:a", 0.0, ANIM_TIME * 0.8)
	tw.tween_callback(s.queue_free)


func has_sheet() -> bool:
	return _sheet != null


## Modal confirmation. Returns (await) true when confirmed.
func confirm(title: String, text: String, ok_text: String = "OK", danger: bool = false) -> bool:
	var result := [null]
	var col := UI.vbox(14)
	col.add_child(UI.label(text, "", true))
	var row := UI.hbox(10)
	var cancel := UI.button("Отмена", "", "", func() -> void: result[0] = false)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ok := UI.button(ok_text, "", "DangerButton" if danger else "AccentButton", func() -> void: result[0] = true)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cancel)
	row.add_child(ok)
	col.add_child(row)
	var s := await sheet(col, title)
	while result[0] == null and is_instance_valid(s) and _sheet == s:
		await get_tree().process_frame
	close_sheet()
	return result[0] == true


## Text input. Returns (await) {ok: bool, text: String}.
func prompt(title: String, initial: String = "", placeholder: String = "", multiline: bool = false) -> Dictionary:
	var result := [null]
	var col := UI.vbox(14)
	var input: Control
	if multiline:
		var te := TextEdit.new()
		te.text = initial
		te.placeholder_text = placeholder
		te.custom_minimum_size.y = 160
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		input = te
	else:
		var le := LineEdit.new()
		le.text = initial
		le.placeholder_text = placeholder
		le.select_all_on_focus = true
		le.text_submitted.connect(func(_t: String) -> void: result[0] = true)
		input = le
	col.add_child(input)
	var row := UI.hbox(10)
	var cancel := UI.button("Отмена", "", "", func() -> void: result[0] = false)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ok := UI.button("Готово", "", "AccentButton", func() -> void: result[0] = true)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cancel)
	row.add_child(ok)
	col.add_child(row)
	var s := await sheet(col, title)
	input.grab_focus()
	while result[0] == null and is_instance_valid(s) and _sheet == s:
		await get_tree().process_frame
	var text: String = input.text
	close_sheet()
	return {"ok": result[0] == true, "text": text}


## Action sheet. items: Array of [id, label, icon(optional), danger(optional)]. Returns (await) id or "".
func choose(title: String, items: Array) -> String:
	var result := [null]
	var col := UI.vbox(2)
	for it in items:
		var id: String = it[0]
		var b := UI.row(str(it[1]), "", it[2] if it.size() > 2 else "", null, func() -> void: result[0] = id)
		if it.size() > 3 and it[3]:
			(b.get_meta("title") as Label).add_theme_color_override("font_color", Style.c("danger"))
		col.add_child(b)
	var s := await sheet(col, title)
	while result[0] == null and is_instance_valid(s) and _sheet == s:
		await get_tree().process_frame
	close_sheet()
	return str(result[0]) if result[0] != null else ""


func toast(message: String, kind: String = "info") -> void:
	if _toasts:
		_toasts.show_toast(message, kind)


## Standard page header: [back] title ... actions
func header(title: String, actions: Array = [], show_back: bool = true) -> Control:
	var h := UI.hbox(4)
	h.custom_minimum_size.y = 52
	if show_back:
		h.add_child(UI.icon_button("back", pop, "Назад"))
	else:
		h.add_child(UI.spacer(0))
	var t := UI.label(title, "TitleLabel")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if not show_back:
		t.add_theme_constant_override("margin_left", 12)
	h.add_child(t)
	for a in actions:
		h.add_child(a)
	return h
