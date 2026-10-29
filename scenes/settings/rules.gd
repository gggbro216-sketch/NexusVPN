extends Control
## Visual editor for routing rules (stored in Settings "custom_rules").
## Rules are validated on entry; conflicts are shown as warnings.

var _list: VBoxContainer
var _warn: VBoxContainer


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(Nav.header("Правила маршрутизации", [UI.icon_button("add", _add, "Добавить правило")]))
	var page := UI.page(10)
	var body := UI.body(page)
	col.add_child(UI.scroll(page))
	body.add_child(UI.label("Правила проверяются сверху вниз, действует первое совпадение. Изменения применяются при следующем подключении.", "CaptionLabel", true))
	_warn = UI.vbox(4)
	body.add_child(_warn)
	_list = UI.vbox(8)
	body.add_child(_list)
	var quick := UI.card(8)
	UI.body(quick).add_child(UI.section("Быстро добавить"))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	for q in [["geosite", "category-ru", "direct", "Российские сайты напрямую"], ["geosite", "category-ads-all", "block", "Блок рекламы"],
			["domain_suffix", "ru", "direct", ".ru напрямую"], ["geoip", "ru", "direct", "IP России напрямую"],
			["geosite", "google", "proxy", "Google через прокси"], ["geosite", "youtube", "proxy", "YouTube через прокси"]]:
		var rule := RulesManager.make_rule(q[0], q[1], q[2])
		flow.add_child(UI.chip(q[3], false, func() -> void: _append(rule)))
	UI.body(quick).add_child(flow)
	body.add_child(quick)
	_rebuild()


func _rules() -> Array:
	return (Settings.get_value("custom_rules") as Array).duplicate(true)


func _save(rules: Array) -> void:
	Settings.set_value("custom_rules", rules)
	_rebuild()


func _append(rule: Dictionary) -> void:
	var err := RulesManager.validate(rule)
	if err != "":
		Nav.toast(err, "error")
		return
	var rules := _rules()
	rules.append(rule)
	_save(rules)


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	for c in _warn.get_children():
		c.queue_free()
	var rules := _rules()
	for w in RulesManager.find_conflicts(rules):
		var l := UI.label("⚠ " + w, "CaptionLabel", true)
		l.add_theme_color_override("font_color", Style.c("warning"))
		_warn.add_child(l)
	if rules.is_empty():
		_list.add_child(UI.label("Правил нет", "MutedLabel"))
	for i in rules.size():
		var r: Dictionary = rules[i]
		var idx := i
		var card := UI.card(4)
		var h := UI.hbox(6)
		var sw := CheckButton.new()
		sw.button_pressed = r.get("enabled", true)
		sw.focus_mode = Control.FOCUS_NONE
		sw.toggled.connect(func(v: bool) -> void:
			var rs := _rules()
			rs[idx]["enabled"] = v
			_save(rs))
		h.add_child(sw)
		var texts := UI.vbox(2)
		texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t := UI.label(str(r.value))
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		texts.add_child(t)
		texts.add_child(UI.label("%s → %s" % [RulesManager.TYPE_LABELS.get(r.type, r.type), RulesManager.ACTION_LABELS.get(r.action, r.action)], "MutedLabel"))
		var err := RulesManager.validate(r)
		if err != "":
			var e := UI.label(err, "CaptionLabel", true)
			e.add_theme_color_override("font_color", Style.c("danger"))
			texts.add_child(e)
		h.add_child(texts)
		h.add_child(UI.icon_button("more", func() -> void: _menu(idx), "Действия", 20))
		UI.body(card).add_child(h)
		_list.add_child(card)


func _menu(idx: int) -> void:
	var c := await Nav.choose("Правило", [["edit", "Изменить", "edit"], ["up", "Выше", "up"], ["down", "Ниже", "down"], ["delete", "Удалить", "delete", true]])
	var rules := _rules()
	match c:
		"edit":
			var r := await _editor(rules[idx])
			if not r.is_empty():
				rules[idx] = r
				_save(rules)
		"up":
			if idx > 0:
				var x: Dictionary = rules[idx]
				rules.remove_at(idx)
				rules.insert(idx - 1, x)
				_save(rules)
		"down":
			if idx < rules.size() - 1:
				var x: Dictionary = rules[idx]
				rules.remove_at(idx)
				rules.insert(idx + 1, x)
				_save(rules)
		"delete":
			rules.remove_at(idx)
			_save(rules)


func _add() -> void:
	var r := await _editor(RulesManager.make_rule("domain_suffix", "", "proxy"))
	if not r.is_empty():
		_append(r)


## Returns (await) the edited rule or {} when cancelled.
func _editor(rule: Dictionary) -> Dictionary:
	var result := [null]
	var col := UI.vbox(10)
	var type_ob := OptionButton.new()
	for i in RulesManager.TYPES.size():
		type_ob.add_item(RulesManager.TYPE_LABELS[RulesManager.TYPES[i]], i)
		if RulesManager.TYPES[i] == rule.type:
			type_ob.select(i)
	var value := LineEdit.new()
	value.text = str(rule.value)
	value.placeholder_text = "example.com, 1.2.3.0/24, ru, 443…"
	var act_ob := OptionButton.new()
	for i in RulesManager.ACTIONS.size():
		act_ob.add_item(RulesManager.ACTION_LABELS[RulesManager.ACTIONS[i]], i)
		if RulesManager.ACTIONS[i] == rule.action:
			act_ob.select(i)
	var err := UI.label("", "CaptionLabel", true)
	err.add_theme_color_override("font_color", Style.c("danger"))
	col.add_child(UI.label("Тип"))
	col.add_child(type_ob)
	col.add_child(UI.label("Значение"))
	col.add_child(value)
	col.add_child(UI.label("Действие"))
	col.add_child(act_ob)
	col.add_child(err)
	var ok := UI.button("Сохранить", "", "AccentButton", func() -> void:
		var r := RulesManager.make_rule(RulesManager.TYPES[type_ob.selected], value.text, RulesManager.ACTIONS[act_ob.selected])
		r.enabled = rule.get("enabled", true)
		var e := RulesManager.validate(r)
		if e != "":
			err.text = e
			return
		result[0] = r)
	col.add_child(ok)
	var s := await Nav.sheet(col, "Правило")
	while result[0] == null and is_instance_valid(s) and Nav.has_sheet():
		await get_tree().process_frame
	Nav.close_sheet()
	return result[0] if result[0] != null else {}
