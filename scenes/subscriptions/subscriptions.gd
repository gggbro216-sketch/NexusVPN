extends Control
## Subscriptions: list with server count, last update, errors, traffic quota
## (subscription-userinfo), manual refresh, URL/name/interval editing.

var _list: VBoxContainer


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 16)
	hm.add_theme_constant_override("margin_right", 16)
	hm.add_child(Nav.header("Подписки", [
		UI.icon_button("refresh", _refresh_all, "Обновить все"),
		UI.icon_button("add", func() -> void: ImportSheet.add_subscription_dialog(), "Добавить подписку"),
	], false))
	col.add_child(hm)
	var page := UI.page(12)
	_list = UI.body(page)
	col.add_child(UI.scroll(page))
	Profiles.subscriptions_changed.connect(_rebuild)
	Subscriptions.update_started.connect(func(_id: String) -> void: _rebuild())
	Subscriptions.update_finished.connect(func(_id: String, _r: Dictionary) -> void: _rebuild())
	_rebuild()


func on_shown() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in _list.get_children():
		c.queue_free()
	var subs := Subscriptions.list()
	if subs.is_empty():
		var v := UI.vbox(12)
		v.add_child(UI.spacer(24))
		var t := UI.label("Подписок пока нет", "HeaderLabel")
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(t)
		var d := UI.label("Подписка — это адрес, по которому провайдер публикует актуальный список серверов. Поддерживаются списки ссылок (в т.ч. base64) и JSON sing-box.", "MutedLabel", true)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(d)
		var b := UI.button("Добавить подписку", "add", "AccentButton", func() -> void: ImportSheet.add_subscription_dialog())
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(b)
		_list.add_child(v)
		return
	for s in subs:
		_list.add_child(_card(s))


func _card(s: Dictionary) -> Control:
	var card := UI.card(6)
	var b := UI.body(card)
	var h := UI.hbox(8)
	var title := UI.label(str(s.name), "HeaderLabel")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(title)
	if not s.get("enabled", true):
		h.add_child(UI.badge("выключена", Style.c("text3")))
	var id: String = s.id
	var busy := Subscriptions.is_updating(id)
	var rb := UI.icon_button("refresh", func() -> void: _refresh(id), "Обновить")
	rb.disabled = busy
	h.add_child(rb)
	h.add_child(UI.icon_button("more", func() -> void: _menu(id), "Действия"))
	b.add_child(h)
	var host := str(UriUtil.parse(str(s.url)).host)
	b.add_child(UI.label(host, "MutedLabel"))
	var line := "Серверов: %d · обновлено: %s" % [int(s.get("count", 0)), UI.fmt_ago(int(s.get("last_success", 0)))]
	if busy:
		line = "Обновление…"
	b.add_child(UI.label(line, "CaptionLabel", true))
	var auto_txt := "автообновление каждые %d ч" % int(s.get("interval_h", 24)) if s.get("auto_update", true) else "автообновление выключено"
	b.add_child(UI.label(auto_txt, "CaptionLabel"))
	var ui: Dictionary = s.get("user_info", {})
	if ui.has("total") and int(ui.total) > 0:
		var used := int(ui.get("upload", 0)) + int(ui.get("download", 0))
		var pb := ProgressBar.new()
		pb.max_value = float(ui.total)
		pb.value = float(used)
		pb.show_percentage = false
		pb.custom_minimum_size.y = 6
		b.add_child(pb)
		b.add_child(UI.label("Трафик: %s из %s" % [UI.fmt_bytes(used), UI.fmt_bytes(int(ui.total))], "CaptionLabel"))
	if int(ui.get("expire", 0)) > 0:
		b.add_child(UI.label("Действует до: " + UI.fmt_datetime(int(ui.expire)), "CaptionLabel"))
	if str(s.get("last_error", "")) != "":
		var e := UI.label("Ошибка: " + str(s.last_error) + " (" + UI.fmt_ago(int(s.get("last_attempt", 0))) + "). Существующие серверы сохранены.", "CaptionLabel", true)
		e.add_theme_color_override("font_color", Style.c("danger"))
		b.add_child(e)
	return card


func _refresh(id: String) -> void:
	var r: Dictionary = await Subscriptions.refresh(id)
	if r.ok:
		Nav.toast("Обновлено: +%d, изменено %d, удалено %d" % [r.added, r.updated, r.removed], "success")
		if r.errors.size() > 0:
			Nav.toast("Пропущено некорректных записей: %d (см. диагностику)" % r.errors.size(), "warning")
			for e in r.errors:
				Log.warn("subscriptions", e)
	else:
		Nav.toast("Ошибка: " + r.error, "error")


func _refresh_all() -> void:
	if Subscriptions.list().is_empty():
		return
	Nav.toast("Обновление подписок…")
	await Subscriptions.refresh_all(false)
	Nav.toast("Подписки обновлены", "success")


func _menu(id: String) -> void:
	var s := Subscriptions.get_sub(id)
	if s.is_empty():
		return
	var choice := await Nav.choose(str(s.name), [
		["rename", "Переименовать", "edit"],
		["url", "Изменить адрес", "link"],
		["interval", "Период обновления", "history"],
		["auto", "Выключить автообновление" if s.get("auto_update", true) else "Включить автообновление", "refresh"],
		["toggle", "Выключить подписку" if s.get("enabled", true) else "Включить подписку", "power"],
		["servers", "Показать серверы", "servers"],
		["copy", "Скопировать адрес", "copy"],
		["delete", "Удалить", "delete", true],
	])
	match choice:
		"rename":
			var r := await Nav.prompt("Название подписки", str(s.name))
			if r.ok and r.text.strip_edges() != "":
				Subscriptions.update_fields(id, {"name": r.text.strip_edges()})
		"url":
			var r := await Nav.prompt("Адрес подписки", str(s.url))
			if r.ok:
				var err := Subscriptions.update_fields(id, {"url": r.text.strip_edges()})
				Nav.toast(err if err != "" else "Адрес изменён", "error" if err != "" else "success")
		"interval":
			var c := await Nav.choose("Обновлять каждые", [["1", "1 час"], ["6", "6 часов"], ["12", "12 часов"], ["24", "24 часа"], ["72", "3 дня"], ["168", "7 дней"]])
			if c != "":
				Subscriptions.update_fields(id, {"interval_h": int(c)})
		"auto":
			Subscriptions.update_fields(id, {"auto_update": not s.get("auto_update", true)})
		"toggle":
			Subscriptions.update_fields(id, {"enabled": not s.get("enabled", true)})
		"servers":
			Nav.show_tab("servers")
		"copy":
			DisplayServer.clipboard_set(str(s.url))
			Nav.toast("Адрес скопирован (может содержать токен доступа)", "warning")
		"delete":
			var c := await Nav.choose("Удалить подписку «%s»?" % s.name, [["all", "Удалить вместе с серверами", "delete", true], ["keep", "Удалить, серверы оставить", "servers"]])
			if c == "all":
				Subscriptions.remove(id, true)
			elif c == "keep":
				Subscriptions.remove(id, false)
