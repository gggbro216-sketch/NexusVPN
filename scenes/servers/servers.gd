extends Control
## Server list: search, filters (favourites / manual / per subscription),
## sorting, compact mode, latency checks, per-server actions.

const PAGE_SIZE := 150

var _search: LineEdit
var _chips: HBoxContainer
var _list: VBoxContainer
var _status: Label
var _filter := "all"
var _sort := "manual"
var _limit := PAGE_SIZE
var _rows := {}
var _dirty := true


func _ready() -> void:
	var col := UI.vbox(10)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	var margin := MarginContainer.new()
	for s in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + s, 16)
	var top := UI.vbox(10)
	margin.add_child(top)
	col.add_child(margin)
	var actions := [
		UI.icon_button("bolt", _test_all, "Проверить все"),
		UI.icon_button("sort", _choose_sort, "Сортировка"),
		UI.icon_button("view", _toggle_compact, "Компактный вид"),
		UI.icon_button("add", func() -> void: ImportSheet.open(), "Добавить"),
	]
	top.add_child(Nav.header("Серверы", actions, false))
	_search = LineEdit.new()
	_search.placeholder_text = "Поиск по названию, адресу, протоколу"
	_search.right_icon = Icons.get_icon("search", 20)
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void:
		_limit = PAGE_SIZE
		_rebuild())
	top.add_child(_search)
	var chip_scroll := ScrollContainer.new()
	chip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chip_scroll.custom_minimum_size.y = 40
	_chips = UI.hbox(8)
	chip_scroll.add_child(_chips)
	top.add_child(chip_scroll)
	_status = UI.label("", "CaptionLabel", true)
	top.add_child(_status)

	var list_margin := MarginContainer.new()
	for s in ["left", "right"]:
		list_margin.add_theme_constant_override("margin_" + s, 16)
	list_margin.add_theme_constant_override("margin_bottom", 24)
	_list = UI.vbox(8)
	list_margin.add_child(_list)
	col.add_child(UI.scroll(list_margin))

	Profiles.profiles_changed.connect(_mark_dirty)
	Profiles.subscriptions_changed.connect(_mark_dirty)
	Profiles.active_changed.connect(func(_id: String) -> void: _update_rows())
	Profiles.profile_updated.connect(_on_profile_updated)
	Latency.progress.connect(func(done: int, total: int) -> void:
		_status.text = "Проверка серверов: %d из %d…" % [done, total])
	Latency.test_finished.connect(func(_r: Dictionary) -> void:
		_status_default()
		if _sort == "latency":
			_rebuild())
	_sort = str(Settings.get_value("server_sort"))
	_rebuild()


func on_shown() -> void:
	if _dirty:
		_rebuild()


func _mark_dirty() -> void:
	_dirty = true
	if is_visible_in_tree():
		_rebuild()


func _build_chips() -> void:
	for c in _chips.get_children():
		c.queue_free()
	var items := [["all", "Все"], ["favorites", "Избранное"], ["manual", "Добавленные вручную"]]
	for s in Subscriptions.list():
		items.append(["sub:" + str(s.id), str(s.name)])
	var found := false
	for it in items:
		if it[0] == _filter:
			found = true
	if not found:
		_filter = "all"
	for it in items:
		var id: String = it[0]
		_chips.add_child(UI.chip(it[1], id == _filter, func() -> void:
			_filter = id
			_limit = PAGE_SIZE
			_rebuild()))


func _rebuild() -> void:
	_dirty = false
	_build_chips()
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	if Profiles.locked:
		_list.add_child(UI.label("Профили недоступны: " + Profiles.lock_reason, "MutedLabel", true))
		return
	var items := Profiles.query(_search.text, _filter, _sort)
	if items.is_empty():
		var empty := UI.vbox(12)
		empty.add_child(UI.spacer(30))
		var t := UI.label("Серверов нет" if Profiles.count() == 0 else "Ничего не найдено", "HeaderLabel")
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_child(t)
		if Profiles.count() == 0:
			var b := UI.button("Добавить сервер", "add", "AccentButton", func() -> void: ImportSheet.open())
			b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			empty.add_child(b)
		_list.add_child(empty)
		_status_default()
		return
	var active := str(Settings.get_value("active_profile_id"))
	var compact := bool(Settings.get_value("compact_list"))
	var shown := 0
	for p in items:
		if shown >= _limit:
			break
		var row := ServerRow.new()
		row.setup(p, p.id == active, compact)
		row.selected.connect(_on_select)
		row.menu_requested.connect(_on_menu)
		row.favorite_toggled.connect(func(id: String, v: bool) -> void: Profiles.set_favorite(id, v))
		_list.add_child(row)
		_rows[p.id] = row
		shown += 1
	if items.size() > _limit:
		var more := UI.button("Показать ещё (%d)" % (items.size() - _limit), "", "FlatButton", func() -> void:
			_limit += PAGE_SIZE
			_rebuild())
		_list.add_child(more)
	_status_default()


func _status_default() -> void:
	var n := Profiles.count()
	var best := Profiles.best_tested()
	_status.text = "Всего серверов: %d" % n
	if best:
		_status.text += " · лучший: %s (%s)" % [best.name, UI.latency_text(best)]


func _update_rows() -> void:
	var active := str(Settings.get_value("active_profile_id"))
	for id in _rows:
		var p := Profiles.get_profile(id)
		if p:
			_rows[id].update_from(p, id == active)


func _on_profile_updated(id: String) -> void:
	if _rows.has(id) and Profiles.has_profile(id):
		_rows[id].update_from(Profiles.get_profile(id), id == str(Settings.get_value("active_profile_id")))


func _on_select(id: String) -> void:
	if id == str(Settings.get_value("active_profile_id")) and not SingBoxManager.is_active():
		Nav.show_tab("dashboard")
		return
	if SingBoxManager.is_active():
		Nav.toast("Переключение сервера…")
		var r: Dictionary = await SingBoxManager.switch_server(id)
		if not r.ok:
			Nav.toast(r.error, "error")
	else:
		Profiles.set_active(id)
		Nav.toast("Выбран: " + Profiles.get_profile(id).name, "success")


func _on_menu(id: String) -> void:
	var p := Profiles.get_profile(id)
	if p == null:
		return
	var items := [
		["select", "Сделать активным", "check"],
		["test", "Проверить задержку", "bolt"],
		["rename", "Переименовать", "edit"],
		["edit", "Подробности и редактирование", "tune"],
		["duplicate", "Дублировать", "copy"],
		["up", "Переместить выше", "up"],
		["down", "Переместить ниже", "down"],
	]
	if p.uri != "":
		items.append(["share", "QR-код / поделиться", "qr"])
	items.append(["delete", "Удалить", "delete", true])
	var choice := await Nav.choose(p.name, items)
	match choice:
		"select":
			_on_select(id)
		"test":
			await Latency.test_profiles([id])
		"rename":
			var r := await Nav.prompt("Название сервера", p.name)
			if r.ok:
				var err := Profiles.rename(id, r.text)
				if err != "":
					Nav.toast(err, "error")
		"edit":
			Nav.push("profile_editor", {"id": id})
		"duplicate":
			var c := Profiles.duplicate_profile(id)
			if c:
				Nav.toast("Создана копия «%s»" % c.name, "success")
		"up":
			Profiles.move(id, -1)
		"down":
			Profiles.move(id, 1)
		"share":
			Nav.push("profile_editor", {"id": id, "show_qr": true})
		"delete":
			if SingBoxManager.is_active() and SingBoxManager.active_profile_id == id:
				Nav.toast("Сначала отключитесь от этого сервера", "warning")
				return
			if await Nav.confirm("Удалить сервер?", "«%s» будет удалён." % p.name, "Удалить", true):
				Profiles.remove(id)


func _test_all() -> void:
	if Latency.running:
		Nav.toast("Проверка уже выполняется")
		return
	var ids := []
	for p in Profiles.query(_search.text, _filter, "manual"):
		ids.append(p.id)
	if ids.is_empty():
		return
	if not SingBoxManager.is_available():
		Nav.toast("Без ядра доступна только TCP-проверка порта (не проверка прокси)", "warning")
	elif SingBoxManager.is_active():
		Nav.toast("VPN подключён: активный сервер проверяется через прокси, остальные — по TCP", "info")
	var res: Dictionary = await Latency.test_profiles(ids)
	var ok := 0
	for id in res:
		if res[id].status in [ProfileModel.LAT_OK, ProfileModel.LAT_SLOW]:
			ok += 1
	Nav.toast("Проверено: %d, доступно: %d" % [res.size(), ok], "success" if ok > 0 else "warning")


func _choose_sort() -> void:
	var c := await Nav.choose("Сортировка", [["manual", "Ручной порядок", "sort"], ["latency", "По задержке", "bolt"],
		["name", "По названию", "servers"], ["best", "Выбрать самый быстрый", "check"]])
	if c == "best":
		var best := Profiles.best_tested()
		if best == null:
			Nav.toast("Нет успешно проверенных серверов — сначала выполните проверку", "warning")
		else:
			_on_select(best.id)
		return
	if c != "":
		_sort = c
		Settings.set_value("server_sort", c)
		_rebuild()


func _toggle_compact() -> void:
	Settings.set_value("compact_list", not bool(Settings.get_value("compact_list")))
	_rebuild()
