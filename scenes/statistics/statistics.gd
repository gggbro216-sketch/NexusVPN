extends Control
## Statistics: live counters from sing-box, daily traffic of recorded
## sessions, session history (persisted, clearable).

var _live: VBoxContainer
var _vals := {}
var _chart: Control
var _history: VBoxContainer
var _totals: Label


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 16)
	hm.add_theme_constant_override("margin_right", 16)
	hm.add_child(Nav.header("Статистика", [UI.icon_button("delete", _clear, "Очистить историю")], false))
	col.add_child(hm)
	var page := UI.page(14)
	var body := UI.body(page)
	col.add_child(UI.scroll(page))

	var live := UI.card(8)
	_live = UI.body(live)
	_live.add_child(UI.section("Текущая сессия"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	for k in [["server", "Сервер"], ["state", "Состояние"], ["down", "Входящая скорость"], ["up", "Исходящая скорость"],
			["down_total", "Принято"], ["up_total", "Отправлено"], ["duration", "Длительность"], ["conns", "Соединений"], ["last", "Последнее подключение"]]:
		grid.add_child(UI.label(k[1], "MutedLabel"))
		var v := UI.label("—")
		v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(v)
		_vals[k[0]] = v
	_live.add_child(grid)
	_live.add_child(UI.label("Источник данных: счётчики трафика ядра sing-box (через TUN), обновление раз в секунду.", "CaptionLabel", true))
	body.add_child(live)

	var chart_card := UI.card(8)
	UI.body(chart_card).add_child(UI.section("Трафик по дням (14 дней, записанные сессии)"))
	_chart = DailyChart.new()
	_chart.custom_minimum_size.y = 120
	UI.body(chart_card).add_child(_chart)
	body.add_child(chart_card)

	_totals = UI.label("", "MutedLabel", true)
	body.add_child(_totals)
	body.add_child(UI.section("История сессий"))
	_history = UI.vbox(8)
	body.add_child(_history)

	SingBoxManager.stats_updated.connect(func(_s: Dictionary) -> void:
		if is_visible_in_tree():
			_refresh_live())
	SingBoxManager.state_changed.connect(func(_s: int, _m: String) -> void: _refresh_live())
	History.changed.connect(_refresh_history)
	_refresh_live()
	_refresh_history()


func on_shown() -> void:
	_refresh_live()
	_refresh_history()


func _refresh_live() -> void:
	var s := SingBoxManager.get_statistics()
	var connected := SingBoxManager.state == VpnState.State.CONNECTED
	_vals.server.text = SingBoxManager.active_profile_name if SingBoxManager.is_active() else "—"
	_vals.state.text = VpnState.label(SingBoxManager.state)
	var live: bool = connected and s.source != ""
	_vals.down.text = UI.fmt_speed(int(s.down)) if live else "—"
	_vals.up.text = UI.fmt_speed(int(s.up)) if live else "—"
	_vals.down_total.text = UI.fmt_bytes(int(s.down_total)) if live else "—"
	_vals.up_total.text = UI.fmt_bytes(int(s.up_total)) if live else "—"
	_vals.conns.text = str(int(s.connections)) if live else "—"
	_vals.duration.text = UI.fmt_duration(int(Time.get_unix_time_from_system()) - SingBoxManager.connected_since) if connected and SingBoxManager.connected_since > 0 else "—"
	_vals.last.text = UI.fmt_datetime(History.last_connected_at())


func _refresh_history() -> void:
	if not is_inside_tree():
		return
	for c in _history.get_children():
		c.queue_free()
	var t := History.totals()
	_totals.text = "Сессий: %d · всего принято %s, отправлено %s · время в сети %s" % [t.count, UI.fmt_bytes(t.down), UI.fmt_bytes(t.up), UI.fmt_duration(t.seconds)]
	(_chart as DailyChart).set_sessions(History.sessions)
	if History.sessions.is_empty():
		_history.add_child(UI.label("История пуста", "MutedLabel"))
		return
	var shown := 0
	for i in range(History.sessions.size() - 1, -1, -1):
		if shown >= 100:
			break
		shown += 1
		var s: Dictionary = History.sessions[i]
		var card := UI.card(2)
		var b := UI.body(card)
		var h := UI.hbox(8)
		var n := UI.label(str(s.get("profile_name", "?")))
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.add_child(n)
		var res := str(s.get("result", "ok"))
		var badge_text := "ошибка" if res == "error" else ("прервана" if res == "interrupted" else ("идёт" if int(s.get("end", 0)) == 0 else "ок"))
		var badge_col: Color = Style.c("danger") if res == "error" else (Style.c("warning") if res == "interrupted" else Style.c("success"))
		h.add_child(UI.badge(badge_text, badge_col))
		b.add_child(h)
		var end := int(s.get("end", 0))
		var dur := (end if end > 0 else int(Time.get_unix_time_from_system())) - int(s.get("start", 0))
		b.add_child(UI.label("%s · %s · %s" % [UI.fmt_datetime(int(s.get("start", 0))), UI.fmt_duration(maxi(dur, 0)), str(s.get("protocol", ""))], "CaptionLabel"))
		b.add_child(UI.label("↓ %s  ↑ %s" % [UI.fmt_bytes(int(s.get("down_bytes", 0))), UI.fmt_bytes(int(s.get("up_bytes", 0)))], "CaptionLabel"))
		if str(s.get("error", "")) != "":
			var e := UI.label(str(s.error), "CaptionLabel", true)
			e.add_theme_color_override("font_color", Style.c("danger"))
			b.add_child(e)
		_history.add_child(card)


func _clear() -> void:
	if await Nav.confirm("Очистить историю?", "Все записи о сессиях будут удалены.", "Очистить", true):
		History.clear()
		Nav.toast("История очищена", "success")


class DailyChart extends Control:
	var _days: Array = []

	func set_sessions(sessions: Array) -> void:
		var now := int(Time.get_unix_time_from_system())
		var tz: int = Time.get_time_zone_from_system().get("bias", 0) * 60
		var today := int((now + tz) / 86400)
		_days = []
		for i in 14:
			_days.append(0)
		for s in sessions:
			var d := int((int(s.get("start", 0)) + tz) / 86400)
			var idx := 13 - (today - d)
			if idx >= 0 and idx < 14:
				_days[idx] += int(s.get("down_bytes", 0)) + int(s.get("up_bytes", 0))
		queue_redraw()

	func _draw() -> void:
		if _days.is_empty():
			return
		var mx := 1
		for v in _days:
			mx = maxi(mx, v)
		var w := size.x / 14.0
		var h := size.y - 18.0
		for i in 14:
			var bh: float = maxf(2.0, h * float(_days[i]) / float(mx)) if _days[i] > 0 else 2.0
			var col: Color = Style.c("accent") if _days[i] > 0 else Style.c("surface3")
			draw_rect(Rect2(i * w + w * 0.2, h - bh, w * 0.6, bh), col)
		var f := get_theme_default_font()
		draw_string(f, Vector2(0, size.y - 2), "−13 дн", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.c("text3"))
		draw_string(f, Vector2(size.x - 50, size.y - 2), "сегодня", HORIZONTAL_ALIGNMENT_RIGHT, 50, 11, Style.c("text3"))
		if mx > 1:
			draw_string(f, Vector2(0, 11), "макс. " + UI.fmt_bytes(mx), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.c("text3"))
