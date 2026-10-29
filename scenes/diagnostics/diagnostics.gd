extends Control
## Diagnostics: live log (app + sing-box) with level/source filters, copy,
## clear, report without secrets, log level settings.

const MAX_RENDER := 800
const LEVEL_COLORS := ["text3", "text2", "warning", "danger"]

var _log: RichTextLabel
var _level := Log.Level.INFO
var _source := ""
var _status: Label
var _pending := false


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(Nav.header("Диагностика", [
		UI.icon_button("copy", _copy, "Копировать журнал"),
		UI.icon_button("delete", _clear, "Очистить"),
	]))
	var top := MarginContainer.new()
	top.add_theme_constant_override("margin_left", 16)
	top.add_theme_constant_override("margin_right", 16)
	var tv := UI.vbox(8)
	top.add_child(tv)
	col.add_child(top)
	_status = UI.label("", "CaptionLabel", true)
	tv.add_child(_status)
	var lv := HFlowContainer.new()
	lv.add_theme_constant_override("h_separation", 6)
	lv.add_theme_constant_override("v_separation", 6)
	for it in [[Log.Level.DEBUG, "Debug"], [Log.Level.INFO, "Info"], [Log.Level.WARNING, "Warning"], [Log.Level.ERROR, "Error"]]:
		var lvl: int = it[0]
		var chip := UI.chip(it[1], lvl == _level, func() -> void:
			_level = lvl
			_render())
		chip.button_group = _level_group()
		lv.add_child(chip)
	tv.add_child(lv)
	var src := HFlowContainer.new()
	src.add_theme_constant_override("h_separation", 6)
	src.add_theme_constant_override("v_separation", 6)
	for it in [["", "Все"], [Log.SOURCE_APP, "Приложение"], [Log.SOURCE_CORE, "sing-box"]]:
		var s: String = it[0]
		var chip := UI.chip(it[1], s == _source, func() -> void:
			_source = s
			_render())
		chip.button_group = _source_group()
		src.add_child(chip)
	tv.add_child(src)
	var actions := UI.hbox(8)
	var rep := UI.button("Отчёт", "file", "", _report)
	rep.tooltip_text = "Отчёт без секретов"
	rep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cfg := UI.button("Проверка конфигурации", "check", "", _check_config)
	cfg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(rep)
	actions.add_child(cfg)
	tv.add_child(actions)
	var levels := UI.hbox(8)
	var a := UI.option_row("Журнал приложения", "", "app_log_level", [[0, "Debug"], [1, "Info"], [2, "Warning"], [3, "Error"]])
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := UI.option_row("Журнал sing-box", "", "core_log_level", [["debug", "debug"], ["info", "info"], ["warn", "warn"], ["error", "error"]])
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	levels.add_child(a)
	levels.add_child(c)
	tv.add_child(levels)

	var lm := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		lm.add_theme_constant_override("margin_" + s, 12)
	lm.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Style.box(Style.c("surface"), 12, Style.c("border"), 1, 8))
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 12)
	panel.add_child(_log)
	lm.add_child(panel)
	col.add_child(lm)
	Log.entry_added.connect(func(_e: Dictionary) -> void: _schedule())
	Log.cleared.connect(_render)
	SingBoxManager.state_changed.connect(func(_s: int, _m: String) -> void: _update_status())
	_update_status()
	_render()


var _lg: ButtonGroup
var _sg: ButtonGroup


func _level_group() -> ButtonGroup:
	if _lg == null:
		_lg = ButtonGroup.new()
	return _lg


func _source_group() -> ButtonGroup:
	if _sg == null:
		_sg = ButtonGroup.new()
	return _sg


func _update_status() -> void:
	var core := ("sing-box " + SingBoxManager.core_version()) if SingBoxManager.is_available() else "ядро недоступно (%s)" % OS.get_name()
	_status.text = "%s · VPN: %s%s" % [core, VpnState.label(SingBoxManager.state),
		(" — " + SingBoxManager.state_message) if SingBoxManager.state_message != "" else ""]


## Batches redraws: logs may arrive in bursts.
func _schedule() -> void:
	if _pending or not is_visible_in_tree():
		return
	_pending = true
	await get_tree().create_timer(0.3).timeout
	_pending = false
	_render()


func _render() -> void:
	var entries := Log.get_entries(_level, _source)
	if entries.size() > MAX_RENDER:
		entries = entries.slice(entries.size() - MAX_RENDER)
	var parts := PackedStringArray()
	for e in entries:
		var t := Time.get_time_string_from_unix_time(int(e.time) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
		var col: Color = Style.c(LEVEL_COLORS[e.level])
		var src: String = "core" if e.source == Log.SOURCE_CORE else e.tag
		parts.append("[color=#%s]%s %s[/color] [color=#%s]%s:[/color] %s" % [Style.c("text3").to_html(false), t, Log.LEVEL_NAMES[e.level],
			col.to_html(false), src, _escape(e.message)])
	_log.text = "\n".join(parts) if parts.size() > 0 else "[color=#%s]Журнал пуст[/color]" % Style.c("text3").to_html(false)


static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


func _copy() -> void:
	DisplayServer.clipboard_set(Log.export_text(_level))
	Nav.toast("Журнал скопирован (секреты замаскированы)", "success")


func _clear() -> void:
	Log.clear()


func _report() -> void:
	var text := DiagnosticReport.build()
	var c := await Nav.choose("Диагностический отчёт", [["copy", "Скопировать в буфер", "copy"], ["save", "Сохранить в файл", "file"], ["share", "Поделиться", "share"]])
	match c:
		"copy":
			DisplayServer.clipboard_set(text)
			Nav.toast("Отчёт скопирован", "success")
		"save":
			load("res://scenes/settings/settings_page.gd").FileExport.save("nexusvpn-report-%s.txt" % Time.get_date_string_from_system(), "text/plain", text)
		"share":
			if Platform.has_vpn_backend():
				Platform.bridge.shareText(text, "Диагностический отчёт")
			else:
				DisplayServer.clipboard_set(text)
				Nav.toast("Отчёт скопирован в буфер", "success")


func _check_config() -> void:
	var p := Profiles.get_active()
	if p == null:
		Nav.toast("Активный сервер не выбран", "warning")
		return
	var r: Dictionary = SingBoxManager.validate_profile(p.id)
	if r.ok:
		Log.info("diagnostics", "config for %s is valid%s" % [p.name, " (core check)" if SingBoxManager.is_available() else " (structure only)"])
		Nav.toast("Конфигурация корректна" + ("" if SingBoxManager.is_available() else " (без проверки ядром)"), "success")
	else:
		Log.error("diagnostics", "config for %s: %s" % [p.name, r.error])
		Nav.toast(r.error, "error")
	for w in r.warnings:
		Log.warn("config", w)
