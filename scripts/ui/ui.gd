class_name UI
extends RefCounted
## Small UI construction kit used by all screens (code-built layouts keep the
## .tscn files minimal and the look consistent).


static func vbox(sep: int = 12) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func hbox(sep: int = 10) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func label(text: String, variation: String = "", wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size.x = 40
	return l


static func colored(text: String, color: Color, size: int = 0, bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	if bold:
		l.add_theme_font_override("font", Style.font_bold)
	return l


static func button(text: String, icon: String = "", variation: String = "", cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	if icon != "":
		b.icon = Icons.get_icon(icon, 22)
	if variation != "":
		b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func icon_button(icon: String, cb: Callable = Callable(), tooltip: String = "", size: int = 24) -> Button:
	var b := Button.new()
	b.icon = Icons.get_icon(icon, size)
	b.theme_type_variation = "FlatButton"
	b.tooltip_text = tooltip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(44, 44)
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_constant_override("icon_max_width", size)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func chip(text: String, pressed: bool = false, cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = pressed
	b.theme_type_variation = "ChipButton"
	b.focus_mode = Control.FOCUS_NONE
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func icon(name: String, size: int = 22, color: Color = Color(-1, 0, 0)) -> TextureRect:
	var t := TextureRect.new()
	t.texture = Icons.get_icon(name, size)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = color if color.r >= 0 else Style.c("text2")
	return t


## Card panel with a vertical body; returns the PanelContainer. Body: card.get_meta("body").
static func card(sep: int = 10, variation: String = "Card") -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = variation
	var body := vbox(sep)
	p.add_child(body)
	p.set_meta("body", body)
	return p


static func body(card: Control) -> VBoxContainer:
	return card.get_meta("body")


static func section(text: String) -> Label:
	var l := label(text.to_upper(), "SectionLabel")
	l.add_theme_constant_override("outline_size", 0)
	return l


static func spacer(h: int = 8) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func expand() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func separator() -> HSeparator:
	return HSeparator.new()


static func scroll(content: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.follow_focus = true
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(content)
	return s


## Padded column used as the root content of screens.
static func page(sep: int = 14) -> MarginContainer:
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 16)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 24)
	var col := vbox(sep)
	m.add_child(col)
	m.set_meta("body", col)
	return m


static func badge(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := Style.box(Color(color, 0.16), 999)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var l := colored(text, color, 11, true)
	p.add_child(l)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## A tappable list row: [icon] title/subtitle ... [right] [chevron].
static func row(title: String, subtitle: String = "", icon_name: String = "", right: Control = null, on_tap: Callable = Callable()) -> Control:
	var btn := Button.new()
	btn.theme_type_variation = "FlatButton"
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size.y = 56 if subtitle != "" else 48
	btn.clip_contents = false
	var h := hbox(12)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 4
	h.offset_right = -4
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon_name != "":
		h.add_child(icon(icon_name, 22))
	var texts := vbox(1)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := label(title)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(t)
	if subtitle != "":
		var s := label(subtitle, "MutedLabel")
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texts.add_child(s)
		btn.set_meta("subtitle", s)
	h.add_child(texts)
	if right != null:
		h.add_child(right)
	if on_tap.is_valid():
		btn.pressed.connect(on_tap)
		if right == null:
			h.add_child(icon("chevron", 20, Style.c("text3")))
	else:
		btn.mouse_filter = Control.MOUSE_FILTER_PASS
	btn.add_child(h)
	btn.set_meta("title", t)
	return btn


## Switch bound to a Settings key.
static func toggle_row(title: String, subtitle: String, key: String, on_change: Callable = Callable(), enabled: bool = true) -> Control:
	var sw := CheckButton.new()
	sw.focus_mode = Control.FOCUS_NONE
	sw.button_pressed = bool(Settings.get_value(key))
	sw.disabled = not enabled
	sw.toggled.connect(func(v: bool) -> void:
		Settings.set_value(key, v)
		if on_change.is_valid():
			on_change.call(v))
	var r := row(title, subtitle, "", sw)
	r.pressed.connect(func() -> void:
		if not sw.disabled:
			sw.button_pressed = not sw.button_pressed)
	return r


## Option selector bound to a Settings key. options: Array of [value, label].
static func option_row(title: String, subtitle: String, key: String, options: Array, on_change: Callable = Callable()) -> Control:
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	ob.fit_to_longest_item = false
	ob.custom_minimum_size.x = 120
	var current: Variant = Settings.get_value(key)
	for i in options.size():
		ob.add_item(str(options[i][1]), i)
		if options[i][0] == current:
			ob.select(i)
	ob.item_selected.connect(func(i: int) -> void:
		Settings.set_value(key, options[i][0])
		if on_change.is_valid():
			on_change.call(options[i][0]))
	var v := vbox(6)
	v.add_child(label(title))
	if subtitle != "":
		v.add_child(label(subtitle, "MutedLabel", true))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(ob)
	return v


static func number_row(title: String, subtitle: String, key: String, min_v: float, max_v: float, step: float = 1.0, suffix: String = "") -> Control:
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.suffix = suffix
	sb.value = float(Settings.get_value(key))
	sb.custom_minimum_size.x = 130
	sb.value_changed.connect(func(v: float) -> void:
		Settings.set_value(key, int(v) if step >= 1.0 else v))
	return row(title, subtitle, "", sb)


## LineEdit bound to a Settings key; [param validate] returns "" or an error.
static func text_row(title: String, subtitle: String, key: String, placeholder: String = "", validate: Callable = Callable()) -> Control:
	var v := vbox(6)
	v.add_child(label(title))
	if subtitle != "":
		v.add_child(label(subtitle, "MutedLabel", true))
	var le := LineEdit.new()
	le.text = str(Settings.get_value(key))
	le.placeholder_text = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var err := label("", "CaptionLabel", true)
	err.add_theme_color_override("font_color", Style.c("danger"))
	err.visible = false
	var commit := func(_t: String = "") -> void:
		var val := le.text.strip_edges()
		var e: String = validate.call(val) if validate.is_valid() else ""
		err.text = e
		err.visible = e != ""
		if e == "":
			Settings.set_value(key, val)
	le.text_submitted.connect(commit)
	le.focus_exited.connect(commit)
	v.add_child(le)
	v.add_child(err)
	return v


static func fmt_bytes(b: int) -> String:
	var units := ["Б", "КБ", "МБ", "ГБ", "ТБ"]
	var v := float(b)
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1
	if i == 0:
		return "%d %s" % [b, units[0]]
	return "%.1f %s" % [v, units[i]] if v < 100 else "%d %s" % [int(v), units[i]]


static func fmt_speed(bps: int) -> String:
	return fmt_bytes(bps) + "/с"


static func fmt_duration(secs: int) -> String:
	var h := secs / 3600
	var m := (secs % 3600) / 60
	var s := secs % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%02d:%02d" % [m, s]


static func fmt_ago(unix: int) -> String:
	if unix <= 0:
		return "никогда"
	var d := int(Time.get_unix_time_from_system()) - unix
	if d < 60:
		return "только что"
	if d < 3600:
		return "%d мин назад" % (d / 60)
	if d < 86400:
		return "%d ч назад" % (d / 3600)
	return "%d дн назад" % (d / 86400)


static func fmt_datetime(unix: int) -> String:
	if unix <= 0:
		return "—"
	var tz: int = Time.get_time_zone_from_system().get("bias", 0) * 60
	var dt := Time.get_datetime_dict_from_unix_time(unix + tz)
	return "%02d.%02d.%04d %02d:%02d" % [dt.day, dt.month, dt.year, dt.hour, dt.minute]


## Regional-indicator emoji flag for an ISO country code ("NL" -> 🇳🇱).
static func flag(cc: String) -> String:
	if cc.length() != 2:
		return ""
	var u := cc.to_upper()
	var a := u.unicode_at(0)
	var b := u.unicode_at(1)
	if a < 65 or a > 90 or b < 65 or b > 90:
		return ""
	return char(0x1F1E6 + a - 65) + char(0x1F1E6 + b - 65)


static func latency_color(p: ProfileModel) -> Color:
	match p.latency_status():
		ProfileModel.LAT_OK:
			return Style.c("success")
		ProfileModel.LAT_SLOW:
			return Style.c("warning")
		ProfileModel.LAT_FAILED:
			return Style.c("danger")
	return Style.c("text3")


static func latency_text(p: ProfileModel) -> String:
	match p.latency_status():
		ProfileModel.LAT_OK, ProfileModel.LAT_SLOW:
			return "%d мс%s" % [int(p.latency.get("ms", 0)), " TCP" if p.latency.get("method", "") == "tcp" else ""]
		ProfileModel.LAT_FAILED:
			return "недоступен"
		ProfileModel.LAT_TESTING:
			return "проверка…"
	return "—" if str(p.latency.get("error", "")) == "" else "н/д"
