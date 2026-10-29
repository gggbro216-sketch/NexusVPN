extends Control
## Main screen: connect button, real connection state, selected server,
## exit IP, session time and traffic figures reported by sing-box.

var _btn: ConnectButton
var _state_label: Label
var _state_msg: Label
var _server_title: Label
var _server_sub: Label
var _server_lat: Label
var _ip_value: Label
var _time_value: Label
var _down_value: Label
var _up_value: Label
var _total_value: Label
var _stats_note: Label
var _banner: PanelContainer
var _banner_text: Label
var _timer: Timer
var _body: VBoxContainer


func _ready() -> void:
	var page := UI.page(16)
	_body = UI.body(page)
	var sc := UI.scroll(page)
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sc)
	_build_header()
	_build_banner()
	_build_connect()
	_build_server_card()
	_build_stats()
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(_tick)
	add_child(_timer)
	SingBoxManager.state_changed.connect(func(_s: int, _m: String) -> void: _refresh())
	SingBoxManager.stats_updated.connect(_on_stats)
	SingBoxManager.ip_info_updated.connect(func(_i: Dictionary) -> void: _refresh_ip())
	Profiles.active_changed.connect(func(_id: String) -> void: _refresh_server())
	Profiles.profile_updated.connect(func(id: String) -> void:
		if id == str(Settings.get_value("active_profile_id")):
			_refresh_server())
	Profiles.profiles_changed.connect(_refresh_server)
	Bus.network_changed.connect(func(_i: Dictionary) -> void: _refresh())
	_refresh()


func on_shown() -> void:
	_refresh()


func on_hidden() -> void:
	_timer.stop()


func _build_header() -> void:
	var h := UI.hbox(12)
	h.custom_minimum_size.y = 56
	var logo := PanelContainer.new()
	logo.add_theme_stylebox_override("panel", Style.box(Color(Style.c("accent"), 0.16), 12, Color.TRANSPARENT, 0, 8))
	logo.add_child(UI.icon("shield", 22, Style.c("accent")))
	h.add_child(logo)
	var name := UI.label(App.app_name(), "TitleLabel")
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(name)
	h.add_child(UI.icon_button("add", func() -> void: ImportSheet.open(), "Добавить сервер"))
	_body.add_child(h)


func _build_banner() -> void:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", Style.box(Color(Style.c("warning"), 0.12), 12, Color(Style.c("warning"), 0.4), 1, 12))
	var h := UI.hbox(10)
	h.add_child(UI.icon("warning", 20, Style.c("warning")))
	_banner_text = UI.label("", "", true)
	h.add_child(_banner_text)
	_banner.add_child(h)
	_banner.visible = false
	_body.add_child(_banner)


func _build_connect() -> void:
	var v := UI.vbox(6)
	_btn = ConnectButton.new()
	_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_btn.clicked.connect(_on_connect_pressed)
	v.add_child(UI.spacer(4))
	v.add_child(_btn)
	_state_label = UI.label("", "TitleLabel")
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_state_label)
	_state_msg = UI.label("", "MutedLabel", true)
	_state_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_state_msg)
	_body.add_child(v)


func _build_server_card() -> void:
	var card := UI.card(4)
	var row := UI.hbox(12)
	var texts := UI.vbox(2)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_title = UI.label("", "HeaderLabel")
	_server_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_server_sub = UI.label("", "MutedLabel")
	_server_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(UI.label("СЕРВЕР", "SectionLabel"))
	texts.add_child(_server_title)
	texts.add_child(_server_sub)
	row.add_child(texts)
	_server_lat = UI.label("", "MutedLabel")
	row.add_child(_server_lat)
	row.add_child(UI.icon("chevron", 20, Style.c("text3")))
	UI.body(card).add_child(row)
	card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			Nav.show_tab("servers"))
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_body.add_child(card)


func _stat_cell(title: String, icon: String) -> Array:
	var card := UI.card(4)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := UI.hbox(6)
	h.add_child(UI.icon(icon, 16, Style.c("text3")))
	h.add_child(UI.label(title, "CaptionLabel"))
	UI.body(card).add_child(h)
	var v := UI.label("—", "ValueLabel")
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UI.body(card).add_child(v)
	return [card, v]


func _build_stats() -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	var cells := [["Загрузка", "down"], ["Отдача", "up"], ["Время соединения", "history"], ["Передано", "up_down"]]
	var vals := []
	for c in cells:
		var cell := _stat_cell(c[0], c[1])
		grid.add_child(cell[0])
		vals.append(cell[1])
	_down_value = vals[0]
	_up_value = vals[1]
	_time_value = vals[2]
	_total_value = vals[3]
	_body.add_child(grid)
	var ip := _stat_cell("Внешний IP-адрес", "globe")
	_ip_value = ip[1]
	_ip_value.add_theme_font_size_override("font_size", 17)
	_body.add_child(ip[0])
	_stats_note = UI.label("", "CaptionLabel", true)
	_body.add_child(_stats_note)


func _on_connect_pressed() -> void:
	var st := SingBoxManager.state
	if st in [VpnState.State.CONNECTED, VpnState.State.CONNECTING, VpnState.State.RECONNECTING, VpnState.State.REQUESTING_PERMISSION, VpnState.State.PREPARING]:
		await SingBoxManager.stop_vpn()
		return
	if st == VpnState.State.STOPPING:
		return
	if Profiles.count() == 0:
		ImportSheet.open()
		return
	if Profiles.get_active() == null:
		Nav.show_tab("servers")
		Nav.toast("Выберите сервер", "info")
		return
	var r: Dictionary = await SingBoxManager.start_vpn()
	if not r.ok and r.error != "отменено":
		Nav.toast(r.error, "error")


func _refresh() -> void:
	var st := SingBoxManager.state
	_btn.state = st
	_state_label.text = VpnState.label(st)
	var color := Style.c("text")
	match st:
		VpnState.State.CONNECTED:
			color = Style.c("success")
		VpnState.State.ERROR:
			color = Style.c("danger")
	_state_label.add_theme_color_override("font_color", color)
	_state_msg.text = SingBoxManager.state_message
	_state_msg.visible = SingBoxManager.state_message != ""
	if not SingBoxManager.is_available():
		_banner_text.text = SingBoxManager.unavailable_reason() + ". Импорт, профили и проверка TCP работают; подключение недоступно."
		_banner.visible = true
	elif Profiles.locked:
		_banner_text.text = "Профили недоступны: " + Profiles.lock_reason
		_banner.visible = true
	else:
		_banner.visible = false
	if st == VpnState.State.CONNECTED:
		if _timer.is_stopped():
			_timer.start()
	else:
		_timer.stop()
	_refresh_server()
	_refresh_ip()
	_tick()
	_on_stats(SingBoxManager.get_statistics())


func _refresh_server() -> void:
	if _server_title == null:
		return
	var p := Profiles.get_active()
	if SingBoxManager.is_active() and SingBoxManager.active_profile_id != "":
		var running := Profiles.get_profile(SingBoxManager.active_profile_id)
		if running:
			p = running
	if p == null:
		_server_title.text = "Сервер не выбран" if Profiles.count() > 0 else "Нет серверов"
		_server_sub.text = "Нажмите, чтобы выбрать" if Profiles.count() > 0 else "Нажмите «+», чтобы добавить сервер"
		_server_lat.text = ""
		return
	var flag := UI.flag(p.exit_country)
	_server_title.text = ("%s %s" % [flag, p.name]).strip_edges()
	_server_sub.text = "%s · %s" % [p.protocol_label(), p.display_address() if p.protocol != "config" else "полная конфигурация"]
	_server_lat.text = UI.latency_text(p)
	_server_lat.add_theme_color_override("font_color", UI.latency_color(p))


func _refresh_ip() -> void:
	if SingBoxManager.state != VpnState.State.CONNECTED:
		_ip_value.text = "—"
		return
	if SingBoxManager.exit_ip != "":
		var fl := UI.flag(SingBoxManager.exit_country)
		_ip_value.text = ("%s %s" % [fl, SingBoxManager.exit_ip]).strip_edges()
	elif not Settings.get_value("ip_check_enabled"):
		_ip_value.text = "проверка IP отключена"
	else:
		_ip_value.text = "определяется…"


func _tick() -> void:
	if SingBoxManager.state == VpnState.State.CONNECTED and SingBoxManager.connected_since > 0:
		_time_value.text = UI.fmt_duration(int(Time.get_unix_time_from_system()) - SingBoxManager.connected_since)
	else:
		_time_value.text = "—"


func _on_stats(s: Dictionary) -> void:
	if not is_visible_in_tree() and s.get("source", "") != "":
		return
	var live: bool = SingBoxManager.state == VpnState.State.CONNECTED and s.get("source", "") != ""
	_down_value.text = UI.fmt_speed(int(s.down)) if live else "—"
	_up_value.text = UI.fmt_speed(int(s.up)) if live else "—"
	_total_value.text = ("↓ %s  ↑ %s" % [UI.fmt_bytes(int(s.down_total)), UI.fmt_bytes(int(s.up_total))]) if live else "—"
	_stats_note.text = "Скорость и объём — счётчики ядра sing-box за текущую сессию." if live else ""
