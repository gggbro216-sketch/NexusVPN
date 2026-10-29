class_name ImportSheet
extends RefCounted
## "Add server" sheet: paste/clipboard, file, QR (camera / image), subscription
## URL. Everything ends in Profiles.import_text() or Subscriptions.add().

const MAX_IMPORT_BYTES := 8 * 1024 * 1024


static func open(prefill: String = "") -> void:
	var col := UI.vbox(12)
	var te := TextEdit.new()
	te.placeholder_text = "vless://…, vmess://…, trojan://…\nНесколько ссылок, base64, JSON sing-box или WireGuard"
	te.custom_minimum_size.y = 130
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.text = prefill
	col.add_child(te)

	var paste_row := UI.hbox(10)
	var paste := UI.button("Вставить", "paste", "", func() -> void:
		te.text = DisplayServer.clipboard_get())
	paste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add := UI.button("Добавить", "add", "AccentButton", func() -> void:
		import_text(te.text, ProfileModel.SOURCE_CLIPBOARD))
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste_row.add_child(paste)
	paste_row.add_child(add)
	col.add_child(paste_row)

	col.add_child(UI.section("Другие способы"))
	var grid := UI.vbox(8)
	for it in [["Из файла", "file", pick_file], ["QR-код (камера)", "qr", scan_qr],
			["QR из изображения", "image", scan_qr_image], ["Подписка по URL", "cloud", add_subscription_dialog]]:
		var b := UI.button(it[0], it[1], "", it[2])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		grid.add_child(b)
	col.add_child(grid)
	col.add_child(UI.label("Ссылки разбираются на устройстве. Содержимое буфера обмена никуда не отправляется.", "CaptionLabel", true))
	Nav.sheet(col, "Добавить сервер")


## Imports text; shows a summary. Returns (await) the import result.
static func import_text(text: String, source: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		Nav.toast("Вставьте ссылку или выберите файл", "warning")
		return {}
	if t.length() > MAX_IMPORT_BYTES:
		Nav.toast("Слишком большой объём данных", "error")
		return {}
	var lower := t.to_lower()
	if (lower.begins_with("https://") or lower.begins_with("http://")) and not t.contains("\n"):
		Nav.close_sheet()
		await add_subscription_dialog(t)
		return {}
	var res := Profiles.import_text(t, source)
	if not res.ok:
		Nav.toast("Не удалось импортировать: " + res.error, "error")
		Bus.import_finished.emit(res)
		return res
	if res.is_full_config and res.added.is_empty():
		Nav.close_sheet()
		await _offer_full_config(res.config)
		return res
	Nav.close_sheet()
	if res.added.size() > 0:
		var first: String = res.added[0]
		if Profiles.get_active() == null or res.added.size() == 1:
			Profiles.set_active(first)
	_show_summary(res)
	if res.is_full_config:
		await _offer_full_config(res.config)
	Bus.import_finished.emit(res)
	return res


static func _show_summary(res: Dictionary) -> void:
	var n: int = res.added.size()
	var msg := ""
	if n == 0:
		msg = "Новых серверов нет (дубликатов: %d)" % res.duplicates
	elif n == 1:
		var p := Profiles.get_profile(res.added[0])
		msg = "Добавлен сервер «%s»" % (p.name if p else "")
	else:
		msg = "Добавлено серверов: %d" % n
	if res.duplicates > 0 and n > 0:
		msg += ", дубликатов пропущено: %d" % res.duplicates
	Nav.toast(msg, "success" if n > 0 else "info")
	var problems := PackedStringArray()
	problems.append_array(res.errors)
	problems.append_array(res.warnings)
	if problems.size() > 0:
		for p in problems:
			Log.warn("import", p)
		Nav.toast("Есть замечания (%d) — подробности в диагностике" % problems.size(), "warning")


static func _offer_full_config(config: Dictionary) -> void:
	var has_tun := false
	for ib in config.get("inbounds", []):
		if typeof(ib) == TYPE_DICTIONARY and ib.get("type", "") == "tun":
			has_tun = true
	if not has_tun:
		return
	var ok := await Nav.confirm("Полная конфигурация sing-box",
		"Файл содержит полную конфигурацию с TUN. Сохранить её как отдельный профиль, который запускается без изменений (настройки DNS и маршрутизации приложения к нему не применяются)?",
		"Сохранить профиль")
	if ok:
		var p := Profiles.add_full_config(config, "sing-box config")
		Nav.toast("Профиль «%s» добавлен" % p.name, "success")


static func pick_file() -> void:
	if Platform.has_vpn_backend():
		var bridge: Object = Platform.bridge
		var cb := func(tag: String, name: String, content: String, error: String) -> void:
			if tag != "import":
				return
			if error != "":
				if error != "cancelled":
					Nav.toast("Файл не прочитан: " + error, "error")
				return
			Log.info("import", "file %s (%d bytes)" % [name, content.length()])
			import_text(content, ProfileModel.SOURCE_FILE)
		bridge.connect("file_picked", cb, Object.CONNECT_ONE_SHOT | Object.CONNECT_DEFERRED)
		bridge.pickFile("import")
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.txt, *.json, *.conf, *.yaml ; Конфигурации", "* ; Все файлы"])
	fd.use_native_dialog = true
	fd.file_selected.connect(func(path: String) -> void:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			Nav.toast("Файл не открыт", "error")
			return
		if f.get_length() > MAX_IMPORT_BYTES:
			Nav.toast("Файл больше 8 МБ", "error")
			return
		var text := f.get_as_text()
		fd.queue_free()
		import_text(text, ProfileModel.SOURCE_FILE))
	fd.canceled.connect(fd.queue_free)
	Nav.get_tree().root.add_child(fd)
	fd.popup_centered_ratio(0.8)


static func scan_qr() -> void:
	_qr(false)


static func scan_qr_image() -> void:
	_qr(true)


static func _qr(from_image: bool) -> void:
	if not Platform.has_vpn_backend():
		Nav.toast("Сканирование QR доступно в Android-версии", "warning")
		return
	var bridge: Object = Platform.bridge
	var cb := func(text: String, error: String) -> void:
		if error != "":
			if error != "cancelled":
				Nav.toast("QR: " + error, "error")
			return
		import_text(text, ProfileModel.SOURCE_QR)
	bridge.connect("qr_scanned", cb, Object.CONNECT_ONE_SHOT | Object.CONNECT_DEFERRED)
	if from_image:
		bridge.scanQrFromImage()
	else:
		bridge.scanQr()


static func add_subscription_dialog(prefill_url: String = "") -> void:
	var col := UI.vbox(10)
	var url := LineEdit.new()
	url.placeholder_text = "https://example.com/sub/…"
	url.text = prefill_url
	var name := LineEdit.new()
	name.placeholder_text = "Название (необязательно)"
	var err := UI.label("", "CaptionLabel", true)
	err.add_theme_color_override("font_color", Style.c("danger"))
	col.add_child(UI.label("Адрес подписки"))
	col.add_child(url)
	col.add_child(UI.label("Название"))
	col.add_child(name)
	col.add_child(err)
	var add := UI.button("Добавить и обновить", "cloud", "AccentButton")
	add.pressed.connect(func() -> void:
		var r := Subscriptions.add(url.text, name.text)
		if not r.ok:
			err.text = r.error
			return
		Nav.close_sheet()
		Nav.toast("Подписка добавлена, загрузка…")
		var res: Dictionary = await Subscriptions.refresh(r.id)
		if res.ok:
			Nav.toast("Подписка обновлена: +%d, обновлено %d" % [res.added, res.updated], "success")
			if Profiles.get_active() == null:
				var list := Profiles.query("", "sub:" + r.id)
				if list.size() > 0:
					Profiles.set_active(list[0].id)
		else:
			Nav.toast("Ошибка обновления подписки: " + res.error, "error"))
	col.add_child(add)
	await Nav.sheet(col, "Новая подписка")
