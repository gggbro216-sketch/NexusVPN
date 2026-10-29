extends Control
## Profile details & editor: name, sing-box outbound JSON (secrets hidden until
## revealed), validation through the real core, QR / share link, delete.

var _id := ""
var _show_qr := false
var _p: ProfileModel
var _name: LineEdit
var _json: TextEdit
var _reveal: CheckButton
var _result: Label
var _qr_box: VBoxContainer
var _body: VBoxContainer


func setup(params: Dictionary) -> void:
	_id = str(params.get("id", ""))
	_show_qr = bool(params.get("show_qr", false))


func _ready() -> void:
	_p = Profiles.get_profile(_id)
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(Nav.header(_p.name if _p else "Сервер"))
	var page := UI.page(14)
	_body = UI.body(page)
	col.add_child(UI.scroll(page))
	if _p == null:
		_body.add_child(UI.label("Профиль не найден", "MutedLabel"))
		return
	_build()


func _build() -> void:
	var info := UI.card(6)
	var b := UI.body(info)
	for kv in [["Протокол", _p.protocol_label()], ["Адрес", _p.display_address() if _p.protocol != "config" else "—"],
			["Источник", _source_label()], ["Создан", UI.fmt_datetime(_p.created_at)], ["Изменён", UI.fmt_datetime(_p.updated_at)],
			["Последняя проверка", _latency_line()], ["Страна выхода", (UI.flag(_p.exit_country) + " " + _p.exit_country).strip_edges() if _p.exit_country != "" else "не определялась"]]:
		var h := UI.hbox(8)
		var k := UI.label(kv[0], "MutedLabel")
		k.custom_minimum_size.x = 130
		h.add_child(k)
		var v := UI.label(str(kv[1]), "", true)
		h.add_child(v)
		b.add_child(h)
	_body.add_child(info)
	if _p.is_insecure_tls():
		var warn := UI.label("⚠ Проверка TLS-сертификата отключена ссылкой (allowInsecure/insecure). Соединение можно перехватить без видимых ошибок. Включить проверку: «Показать секреты» → удалить \"insecure\": true → «Сохранить».", "CaptionLabel", true)
		warn.add_theme_color_override("font_color", Style.c("warning"))
		_body.add_child(warn)

	_body.add_child(UI.section("Название"))
	_name = LineEdit.new()
	_name.text = _p.name
	_body.add_child(_name)

	_body.add_child(UI.section("Параметры подключения (sing-box)"))
	_reveal = CheckButton.new()
	_reveal.text = "Показать секреты (UUID, пароли, ключи)"
	_reveal.toggled.connect(func(_v: bool) -> void: _fill_json())
	_body.add_child(_reveal)
	_json = TextEdit.new()
	_json.custom_minimum_size.y = 280
	_json.add_theme_font_size_override("font_size", 13)
	_json.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body.add_child(_json)
	_fill_json()
	_result = UI.label("", "CaptionLabel", true)
	_body.add_child(_result)

	var row := UI.hbox(10)
	var check := UI.button("Проверить ядром", "check", "", _validate)
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var save := UI.button("Сохранить", "", "AccentButton", _save)
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(check)
	row.add_child(save)
	_body.add_child(row)

	_body.add_child(UI.section("Действия"))
	var actions := UI.vbox(8)
	actions.add_child(UI.button("Проверить задержку", "bolt", "", func() -> void:
		await Latency.test_profiles([_id])
		_p = Profiles.get_profile(_id)
		_result.text = "Проверка: " + _latency_line()))
	if _p.uri != "":
		actions.add_child(UI.button("Показать QR-код", "qr", "", _toggle_qr))
		actions.add_child(UI.button("Скопировать ссылку", "copy", "", func() -> void:
			DisplayServer.clipboard_set(_p.uri)
			Nav.toast("Ссылка скопирована. Она содержит секретные данные — делитесь только с доверенными людьми.", "warning")))
	actions.add_child(UI.button("Просмотр итоговой конфигурации (без секретов)", "file", "", func() -> void:
		var te := TextEdit.new()
		te.editable = false
		te.text = SingBoxManager.preview_config_masked(_id)
		te.custom_minimum_size.y = 420
		te.add_theme_font_size_override("font_size", 12)
		Nav.sheet(te, "Конфигурация sing-box")))
	actions.add_child(UI.button("Удалить сервер", "delete", "DangerButton", func() -> void:
		if SingBoxManager.is_active() and SingBoxManager.active_profile_id == _id:
			Nav.toast("Сначала отключитесь от этого сервера", "warning")
			return
		if await Nav.confirm("Удалить сервер?", "«%s» будет удалён." % _p.name, "Удалить", true):
			Profiles.remove(_id)
			Nav.pop()))
	_body.add_child(actions)
	_qr_box = UI.vbox(8)
	_body.add_child(_qr_box)
	if _show_qr:
		_toggle_qr.call_deferred()


func _source_label() -> String:
	var names := {"manual": "вручную", "clipboard": "буфер обмена", "file": "файл", "qr": "QR-код",
		"subscription": "подписка", "singbox_json": "JSON sing-box"}
	var s: String = names.get(_p.source, _p.source)
	if _p.subscription_id != "":
		var sub := Subscriptions.get_sub(_p.subscription_id)
		if not sub.is_empty():
			s += " «%s»" % sub.name
	return s


func _latency_line() -> String:
	if _p.latency.is_empty() or _p.latency_status() == ProfileModel.LAT_UNTESTED and str(_p.latency.get("error", "")) == "":
		return "не выполнялась"
	var m: String = {"proxy": "через прокси", "tcp": "TCP-порт"}.get(_p.latency.get("method", ""), "")
	var t := UI.latency_text(_p)
	if str(_p.latency.get("error", "")) != "":
		t += " (%s)" % _p.latency.error
	return "%s %s, %s" % [t, m, UI.fmt_ago(int(_p.latency.get("checked_at", 0)))]


func _fill_json() -> void:
	var data: Variant = _p.outbound if _reveal.button_pressed else SecretMasker.mask_value(_p.outbound)
	_json.text = JsonUtil.stringify(data, "  ")
	_json.editable = _reveal.button_pressed
	if not _reveal.button_pressed:
		_result.text = "Редактирование доступно после включения «Показать секреты»."


func _collect() -> Dictionary:
	var copy := ProfileModel.from_dict(_p.to_dict())
	copy.name = _name.text.strip_edges()
	if _reveal.button_pressed:
		if _p.protocol == "config":
			var j := JsonUtil.parse(_json.text)
			if not j.ok or typeof(j.data) != TYPE_DICTIONARY:
				return {"ok": false, "error": j.error if not j.ok else "ожидается JSON-объект"}
			copy.outbound = j.data
		else:
			var r := ProfileValidator.parse_outbound_json(_json.text, _p.protocol)
			if not r.ok:
				return {"ok": false, "error": r.error}
			copy.outbound = r.outbound
	return {"ok": true, "profile": copy}


func _validate() -> void:
	var c := _collect()
	if not c.ok:
		_show_result(false, c.error)
		return
	var err := ProfileValidator.validate(c.profile)
	if err != "":
		_show_result(false, err)
		return
	var built := ConfigBuilder.build_vpn_config(c.profile, Settings.export_data())
	if not built.ok:
		_show_result(false, built.error)
		return
	if SingBoxManager.is_available():
		var core_err := SingBoxManager.backend.check_config(JsonUtil.stringify(built.config))
		if core_err != "":
			_show_result(false, "ядро: " + core_err)
			return
		if not built.xray_config.is_empty():
			var xerr := SingBoxManager.backend.check_xray_config(JsonUtil.stringify(built.xray_config))
			if xerr != "":
				_show_result(false, "Xray: " + xerr)
				return
		_show_result(true, "Конфигурация принята ядром sing-box %s" % SingBoxManager.core_version())
	else:
		_show_result(true, "Структура корректна (проверка ядром доступна на Android)")


func _save() -> void:
	var c := _collect()
	if not c.ok:
		_show_result(false, c.error)
		return
	var p: ProfileModel = c.profile
	if p.name != _p.name:
		p.user_renamed = true
	var err := Profiles.update_profile(p)
	if err != "":
		_show_result(false, err)
		return
	_p = p
	Nav.toast("Сохранено", "success")
	if SingBoxManager.is_active() and SingBoxManager.active_profile_id == _id:
		Nav.toast("Изменения применятся после переподключения", "info")


func _show_result(ok: bool, text: String) -> void:
	_result.text = text
	_result.add_theme_color_override("font_color", Style.c("success") if ok else Style.c("danger"))


func _toggle_qr() -> void:
	for c in _qr_box.get_children():
		c.queue_free()
	if not await Nav.confirm("Показать QR-код?", "QR-код содержит полные данные для подключения (включая секреты). Не показывайте его посторонним и не публикуйте снимки экрана.", "Показать"):
		return
	if not Platform.has_vpn_backend():
		_qr_box.add_child(UI.label("Генерация QR доступна в Android-версии; используйте «Скопировать ссылку».", "MutedLabel", true))
		return
	var png: PackedByteArray = Platform.bridge.generateQrPng(_p.uri, 720)
	var img := Image.new()
	if png.is_empty() or img.load_png_from_buffer(png) != OK:
		Nav.toast("Не удалось создать QR-код (ссылка слишком длинная?)", "error")
		return
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(300, 300)
	_qr_box.add_child(tr)
	_qr_box.add_child(UI.button("Скрыть QR-код", "close", "", func() -> void:
		for c in _qr_box.get_children():
			c.queue_free()))
